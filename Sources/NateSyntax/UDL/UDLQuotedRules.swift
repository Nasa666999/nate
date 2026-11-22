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
    private let boundaries: UDLWordBoundary

    /// 业务作用：普通整词与引号短语沿运算符、折叠起中止和八组关键字的明确优先级执行。
    /// 参数说明:
    /// - definition: 本次固定完整 UDL。
    /// - comments: 已校验容量的注释候选。
    /// - delimiters: 已校验容量的分隔符候选。
    /// - budget: 本行全部规则共用的资格。
    /// 返回：没有整词规则时保持轻量空规则，否则建立有界字段与真实结束证据。
    init(
        definition: UDLDefinition,
        comments: [Int: [String]],
        delimiters: [Int: [String]],
        budget: UDLScanBudget
    ) throws {
        self.definition = definition
        boundaries = UDLWordBoundary(
            definition: definition,
            comments: comments,
            delimiters: delimiters
        )
        let enabled = definition.lists.contains {
            key,
            values in
            !values.isEmpty
                && (key.hasPrefix("Keywords") || key == "Operators2"
                    || key.hasPrefix("Folders in code2") || key.hasPrefix("Folders in comment"))
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

    /// 业务作用：整词和短语只从真实词起点取得完整源证据，同位置前向符号保持其优先职责。
    /// 参数说明:
    /// - bytes: 当前完整片段。
    /// - offset: 已确认的词起点。
    /// - base: 片段所属文档字节起点。
    /// - snapshot: 可选的固定完整正文。
    /// - context: 当前实际注释或分隔符及其对应起止位置。
    /// - nesting: 当前允许的嵌套位。
    /// - budget: 词法扫描共同资格。
    /// 返回：最高优先级的完整整词或短语范围，前缀覆盖完整词；缺少证据或前向动作优先时为空。
    func match(
        bytes: [UInt8],
        offset: Int,
        base: Int,
        snapshot: DocumentSnapshot?,
        context: UDLContext?,
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
        let mask = context?.style.contains("COMMENT") == true ? nesting | 0xE00000 : nesting
        let input = UDLWordInput(
            initial: bytes,
            offset: offset,
            base: base,
            snapshot: snapshot,
            budget: budget
        )
        var wordEnd: Int?
        var checkedEnd = false
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
                if !checkedEnd {
                    wordEnd = try boundaries.end(
                        bytes: bytes,
                        offset: offset,
                        context: context,
                        nesting: nesting,
                        budget: budget
                    )
                    checkedEnd = true
                }
                let end: Int?
                if literal.utf8.contains(where: {
                    $0 > 0 && $0 < 33
                }) {
                    end = try boundaries.end(
                        bytes: bytes,
                        offset: offset,
                        after: offset + literal.utf8.count,
                        context: context,
                        nesting: nesting,
                        budget: budget
                    )
                }
                else {
                    end = wordEnd
                }
                if let end, end >= offset + literal.utf8.count,
                    field.prefix || offset + literal.utf8.count == end
                {
                    return UDLQuotedMatch(
                        length: field.prefix ? end - offset : literal.utf8.count,
                        style: field.style,
                        action: field.action
                    )
                }
            }
        }
        return nil
    }
}
