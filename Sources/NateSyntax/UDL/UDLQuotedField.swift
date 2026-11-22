import Foundation

struct UDLQuotedField {
    private struct Key: Hashable {
        let bytes: Data
        let count: Int
    }
    private struct Pattern {
        let parts: [[UInt8]]
        let separators: [UInt8]
    }
    let name: String
    let style: String
    let mask: UInt32
    let prefix: Bool
    let action: SyntaxFoldAction?
    let literals: [String]
    private let first: [String]
    private let groups: [[Pattern]]
    private let ignoreCase: Bool

    /// 业务作用：引号短语按首段共享索引，保留各段空白类型，避免逐字节遍历整份短语表。
    /// 参数说明:
    /// - name: 当前有效规则组。
    /// - style: 匹配后的原词法样式。
    /// - mask: 当前上下文须具备的嵌套位。
    /// - prefix: 是否扩展短语后紧邻的下一完整词。
    /// - action: 可选的折叠起中止职责。
    /// - definition: 当前固定 UDL。
    /// - budget: 规则准备与扫描共同持有的预算。
    /// 返回：原顺序字面候选及有界的短语首段索引。
    init(
        name: String,
        style: String,
        mask: UInt32,
        prefix: Bool,
        action: SyntaxFoldAction?,
        definition: UDLDefinition,
        budget: UDLScanBudget
    ) throws {
        self.name = name
        self.style = style
        self.mask = mask
        self.prefix = prefix
        self.action = action
        ignoreCase = definition.caseIgnored
        var first: [String] = []
        var groups: [[Pattern]] = []
        var lookup: [Key: Int] = [:]
        var literals: [String] = []
        for value in definition.lists[name] ?? [] {
            let bytes = Array(value.utf8)
            try budget.consume(bytes.count + 1)
            guard bytes.contains(11) || bytes.contains(8) else {
                literals.append(value)
                continue
            }
            var parts: [[UInt8]] = []
            var separators: [UInt8] = []
            var start = 0
            for index in bytes.indices where bytes[index] == 11 || bytes[index] == 8 {
                parts.append(Array(bytes[start..<index]))
                separators.append(bytes[index])
                start = index + 1
            }
            parts.append(Array(bytes[start..<bytes.count]))
            guard
                !parts.contains(where: {
                    $0.isEmpty
                })
            else {
                continue
            }
            let head = String(decoding: parts[0], as: UTF8.self)
            let key = Key(
                bytes: Data((definition.caseIgnored ? head.lowercased() : head).utf8),
                count: parts[0].count
            )
            let group: Int
            if let existing = lookup[key] {
                group = existing
            }
            else {
                group = groups.count
                lookup[key] = group
                first.append(head)
                groups.append([])
            }
            groups[group].append(
                Pattern(
                    parts: parts,
                    separators: separators
                )
            )
        }
        self.first = first
        self.groups = groups
        self.literals = literals
    }

    /// 业务作用：短语按对应空白类型匹配完整后续原文，前缀模式只在已成立的词边界扩展下一词。
    /// 参数说明:
    /// - bytes: 当前物理片段。
    /// - offset: 本次候选的完整标量起点。
    /// - input: 固定正文的有界原字节窗口。
    /// - ends: 明确前向规则的结束外观。
    /// - budget: 本行共同执行资格。
    /// 返回：完整匹配的源字节长度，尚未取得终止证据时为空。
    func match(bytes: [UInt8], offset: Int, input: UDLWordInput, ends: Set<UInt8>, budget: UDLScanBudget)
        throws -> Int?
    {
        guard !first.isEmpty,
            let group = try budget.longestIndex(
                key: "quoted:first:" + name,
                patterns: first,
                bytes: bytes,
                offset: offset,
                ignoreCase: ignoreCase
            )
        else {
            return nil
        }
        var longest: Int?
        for pattern in groups[group] {
            var position = 0
            var matched = true
            for index in pattern.parts.indices {
                if index > 0 {
                    let start = position
                    while let byte = try input.byte(at: position),
                        Self.whitespace(byte, mode: pattern.separators[index - 1])
                    {
                        position += 1
                    }
                    if position == start {
                        matched = false
                        break
                    }
                }
                let part = pattern.parts[index]
                var actual: [UInt8] = []
                for _ in part.indices {
                    guard let byte = try input.byte(at: position) else {
                        matched = false
                        break
                    }
                    actual.append(byte)
                    position += 1
                }
                if !matched {
                    break
                }
                let equal =
                    ignoreCase
                    ? String(decoding: actual, as: UTF8.self).lowercased().utf8.elementsEqual(
                        String(decoding: part, as: UTF8.self).lowercased().utf8
                    )
                    : actual == part
                if !equal {
                    matched = false
                    break
                }
                if let next = try input.byte(at: position), next & 0xC0 == 0x80 {
                    matched = false
                    break
                }
            }
            guard matched, let ending = try input.byte(at: position),
                Self.whitespace(ending, mode: 11) || ends.contains(ending)
            else {
                continue
            }
            if prefix, Self.whitespace(ending, mode: 11), let mode = pattern.separators.last {
                var next = position
                while let byte = try input.byte(at: next), Self.whitespace(byte, mode: mode) {
                    next += 1
                }
                let wordStart = next
                while let byte = try input.byte(at: next), !Self.whitespace(byte, mode: mode),
                    !ends.contains(byte)
                {
                    next += 1
                }
                if next > wordStart {
                    position = next
                }
            }
            if longest == nil || position > (longest ?? 0) {
                longest = position
            }
        }
        return longest
    }

    /// 业务作用：单引号短语只跨空格和 Tab，双引号短语可跨真实物理行但不能跨 NUL。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// - mode: 声明中保留的同行或跨行空白标记。
    /// 返回：当前标记允许该字节作为短语间隔时为真。
    private static func whitespace(_ byte: UInt8, mode: UInt8) -> Bool {
        mode == 8 ? byte == 32 || byte == 9 : byte > 0 && byte < 33
    }
}
