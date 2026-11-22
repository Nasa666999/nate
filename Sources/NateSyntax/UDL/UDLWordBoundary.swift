import Foundation

final class UDLWordBoundary {
    private let definition: UDLDefinition
    private let comments: [Int: [String]]
    private let delimiters: [Int: [String]]
    private var ends: [String: [String]] = [:]

    /// 业务作用：整词边界只由当前有权限的前向规则建立，普通标点和 NUL 不能自行截断词。
    /// 参数说明:
    /// - definition: 当前固定完整规则。
    /// - comments: 已完成对应位置展开的注释规则。
    /// - delimiters: 已完成对应位置展开的分隔符规则。
    /// 返回：按当前上下文共享结束索引的有界边界查询器。
    init(definition: UDLDefinition, comments: [Int: [String]], delimiters: [Int: [String]]) {
        self.definition = definition
        self.comments = comments
        self.delimiters = delimiters
    }

    /// 业务作用：在真实空白或启用的完整前向符号处确认整词终止，文件末尾不代替结束证据。
    /// 参数说明:
    /// - bytes: 当前完整物理片段。
    /// - offset: 已确认的整词起点。
    /// - after: 可选的完整字面短语结束位置，其内部空白属于明确声明。
    /// - context: 当前实际对应位置的上下文，空值表示普通代码。
    /// - nesting: 当前上下文授予的嵌套权限。
    /// - budget: 本行规则索引和扫描共同预算。
    /// 返回：原片段内的完整整词终点；只有正文末尾而没有真实结束证据时为空。
    func end(
        bytes: [UInt8],
        offset: Int,
        after: Int? = nil,
        context: UDLContext?,
        nesting: UInt32,
        budget: UDLScanBudget
    ) throws -> Int? {
        let key = String(nesting) + (context == nil ? ":root" : ":nested")
        let patterns: [String]
        if let existing = ends[key] {
            patterns = existing
        }
        else {
            var selected: [String] = []
            if nesting & 0x1000000 != 0 {
                selected += definition.lists["Operators1"] ?? []
            }
            if nesting & 0x100 != 0 {
                selected += comments[3] ?? []
            }
            if nesting & 0x200 != 0, definition.lineCommentPosition == .anywhere {
                selected += comments[0] ?? []
            }
            for group in 0..<8 where nesting & (1 << group) != 0 {
                selected += delimiters[group * 3] ?? []
            }
            if context == nil {
                for action in ["open", "middle", "close"] {
                    selected += definition.lists["Folders in code1, " + action] ?? []
                }
            }
            try budget.consume(selected.count)
            ends[key] = selected
            patterns = selected
        }
        var position = after ?? offset + 1
        while position < bytes.count {
            try budget.consume()
            if bytes[position] > 0 && bytes[position] < 33 {
                return position
            }
            if bytes[position] & 0xC0 == 0x80 {
                position += 1
                continue
            }
            if let context,
                let escape = try budget.longest(
                    key: context.ruleKey + ":escape",
                    patterns: context.escapes,
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored
                )
            {
                position = min(bytes.count, position + escape.utf8.count + 1)
                continue
            }
            if try budget.longest(
                key: "word:end:" + key,
                patterns: patterns,
                bytes: bytes,
                offset: position,
                ignoreCase: definition.caseIgnored
            ) != nil {
                return position
            }
            if let context,
                try budget.longest(
                    key: context.ruleKey + ":end",
                    patterns: context.ends,
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored
                ) != nil
            {
                return position
            }
            position += 1
        }
        return nil
    }
}
