import Foundation
import NateCore

struct UDLQuotedMatch {
    let length: Int
    let style: String
    let action: SyntaxFoldAction?
}

struct UDLQuotedRules {
    private let definition: UDLDefinition
    private let fields: [UDLQuotedField]
    private let ends: Set<UInt8>

    /// 业务作用：引号短语沿整词运算符、折叠起中止和八组关键字的明确优先级执行，共用前向结束证据。
    /// 参数说明:
    /// - definition: 本次固定完整 UDL。
    /// - comments: 已校验容量的注释候选。
    /// - delimiters: 已校验容量的分隔符候选。
    /// - budget: 本行全部规则共用的资格。
    /// 返回：没有引号短语时保持轻量空规则，否则建立有界字段与结束外观。
    init(
        definition: UDLDefinition,
        comments: [Int: [String]],
        delimiters: [Int: [String]],
        budget: UDLScanBudget
    ) throws {
        self.definition = definition
        let enabled = definition.lists.values.contains {
            $0.contains {
                $0.contains("\u{B}") || $0.contains("\u{8}")
            }
        }
        guard enabled else {
            fields = []
            ends = []
            return
        }
        var fields: [UDLQuotedField] = []
        fields.append(
            try UDLQuotedField(
                name: "Operators2",
                style: "OPERATORS",
                mask: 0x2000000,
                prefix: false,
                action: nil,
                definition: definition,
                budget: budget
            )
        )
        for (family, style, mask) in [
            ("Folders in code2", "FOLDER IN CODE2", UInt32(0x40000)),
            ("Folders in comment", "FOLDER IN COMMENT", UInt32(0x200000)),
        ] {
            for (index, action) in ["open", "middle", "close"].enumerated() {
                fields.append(
                    try UDLQuotedField(
                        name: family + ", " + action,
                        style: style,
                        mask: mask << index,
                        prefix: false,
                        action: SyntaxFoldAction(rawValue: index),
                        definition: definition,
                        budget: budget
                    )
                )
            }
        }
        for group in 1...8 {
            fields.append(
                try UDLQuotedField(
                    name: "Keywords\(group)",
                    style: "KEYWORDS\(group)",
                    mask: 1 << (group + 9),
                    prefix: definition.prefix.contains(group),
                    action: nil,
                    definition: definition,
                    budget: budget
                )
            )
        }
        var patterns = definition.lists["Operators1"] ?? []
        for index in 0...4 {
            patterns += comments[index] ?? []
        }
        for group in 0..<8 {
            patterns += delimiters[group * 3 + 2] ?? []
        }
        for action in ["open", "middle", "close"] {
            patterns += definition.lists["Folders in code1, " + action] ?? []
        }
        var ends: Set<UInt8> = []
        for pattern in patterns {
            try budget.consume()
            if let byte = pattern.utf8.first, byte != 0 {
                ends.insert(byte)
                if definition.caseIgnored, (65...90).contains(byte) {
                    ends.insert(byte + 32)
                }
                else if definition.caseIgnored, (97...122).contains(byte) {
                    ends.insert(byte - 32)
                }
            }
        }
        self.fields = fields
        self.ends = ends
    }

    /// 业务作用：短语只从真实词起点取得完整源证据，同位置前向符号与更高优先级字面组保持原职责。
    /// 参数说明:
    /// - bytes: 当前完整片段。
    /// - offset: 已确认的词起点。
    /// - base: 片段所属文档字节起点。
    /// - snapshot: 可选的固定完整正文。
    /// - context: 当前实际注释或分隔符样式。
    /// - nesting: 当前允许的嵌套位。
    /// - budget: 词法扫描共同资格。
    /// 返回：最高优先级的完整短语范围，缺少匹配或应交给已有字面规则时为空。
    func match(
        bytes: [UInt8],
        offset: Int,
        base: Int,
        snapshot: DocumentSnapshot?,
        context: String?,
        nesting: UInt32,
        budget: UDLScanBudget
    ) throws -> UDLQuotedMatch? {
        guard !fields.isEmpty else {
            return nil
        }
        if nesting & 0x1000000 != 0,
            try budget.longest(
                key: "Operators1",
                patterns: definition.lists["Operators1"] ?? [],
                bytes: bytes,
                offset: offset,
                ignoreCase: definition.caseIgnored
            ) != nil
        {
            return nil
        }
        if context == nil {
            for action in ["open", "middle", "close"] {
                let key = "Folders in code1, " + action
                if try budget.longest(
                    key: key,
                    patterns: definition.lists[key] ?? [],
                    bytes: bytes,
                    offset: offset,
                    ignoreCase: definition.caseIgnored
                ) != nil {
                    return nil
                }
            }
        }
        let mask = context?.contains("COMMENT") == true ? nesting | 0xE00000 : nesting
        let input = UDLWordInput(
            initial: bytes,
            offset: offset,
            base: base,
            snapshot: snapshot,
            budget: budget
        )
        for field in fields where mask & field.mask != 0 {
            if let length = try field.match(
                bytes: bytes,
                offset: offset,
                input: input,
                ends: ends,
                budget: budget
            ) {
                return UDLQuotedMatch(
                    length: length,
                    style: field.style,
                    action: field.action
                )
            }
            if !field.literals.isEmpty,
                let literal = try budget.longest(
                    key: field.name,
                    patterns: definition.lists[field.name] ?? [],
                    bytes: bytes,
                    offset: offset,
                    ignoreCase: definition.caseIgnored,
                    literalOnly: true
                )
            {
                let end = offset + literal.utf8.count
                if field.prefix || end == bytes.count || !UDLLexer.word(bytes[end]) {
                    return nil
                }
            }
        }
        return nil
    }
}
