import Foundation

typealias UDLFoldAction = SyntaxFoldAction

struct UDLFolderMatch {
    let text: String
    let style: String
    let action: UDLFoldAction
}

struct UDLFoldRules {
    let definition: UDLDefinition
    let enabled: Bool
    let comments: [Int: [String]]
    let delimiters: [Int: [String]]
    private var forwardEnds: [String: [String]] = [:]
    static let families = [
        (name: "Folders in code1", style: "FOLDER IN CODE1", mask: UInt32(0)),
        (name: "Folders in code2", style: "FOLDER IN CODE2", mask: UInt32(0x40000)),
        (name: "Folders in comment", style: "FOLDER IN COMMENT", mask: UInt32(0x200000)),
    ]
    static let actions = ["open", "middle", "close"]

    /// 业务作用：没有折叠关键字的语言不为每个字节重复解释空组，实际规则仍绑定当前完整定义。
    /// 参数说明:
    /// - definition: 当前固定 UDL 规则代次。
    /// 返回：三组起中止规则及其是否启用的明确状态。
    init(definition: UDLDefinition) {
        self.definition = definition
        comments = UDLLexer.indexed(definition.lists["Comments"] ?? [])
        delimiters = UDLLexer.indexed(definition.lists["Delimiters"] ?? [])
        enabled = Self.families.contains {
            family in
            Self.actions.contains {
                !(definition.lists[family.name + ", " + $0] ?? []).isEmpty
            }
        }
    }

    /// 业务作用：前向字面组和整词组按明确优先级及嵌套权限识别，运算符不能同时取得折叠权。
    /// 参数说明:
    /// - bytes: 当前完整物理行。
    /// - offset: 当前完整标量边界。
    /// - context: 当前注释或分隔符上下文，为空时处于普通代码。
    /// - nesting: 当前上下文明示的嵌套位集合。
    /// - wordStart: 前一段真实空白或已识别的前向规则是否建立了整词起点。
    /// - contextEnds: 当前上下文本身的闭合候选。
    /// - budget: 所有规则索引和匹配共同持有的预算。
    /// 返回：首个允许的完整起中止标记，不匹配时为空；超量或失权时抛错。
    mutating func match(
        bytes: [UInt8],
        offset: Int,
        context: String?,
        nesting: UInt32,
        wordStart: Bool,
        contextEnds: [String],
        budget: UDLScanBudget
    ) throws -> UDLFolderMatch? {
        guard enabled else {
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
        if context == nil,
            let literal = try family(
                0,
                bytes: bytes,
                at: offset,
                mask: UInt32.max,
                ends: [],
                endKey: "DEFAULT",
                budget: budget
            )
        {
            return literal
        }
        guard wordStart else {
            return nil
        }
        let endKey = context ?? "DEFAULT"
        let ends: [String]
        if let existing = forwardEnds[endKey] {
            ends = existing
        }
        else {
            ends = try terminators(
                context: context,
                nesting: nesting,
                contextEnds: contextEnds,
                budget: budget
            )
            forwardEnds[endKey] = ends
        }
        if nesting & 0x2000000 != 0,
            let op = try budget.longest(
                key: "Operators2",
                patterns: definition.lists["Operators2"] ?? [],
                bytes: bytes,
                offset: offset,
                ignoreCase: definition.caseIgnored
            ),
            offset + op.utf8.count == bytes.count || !UDLLexer.word(bytes[offset + op.utf8.count])
        {
            return nil
        }
        let mask = context?.contains("COMMENT") == true ? nesting | 0xE00000 : nesting
        for group in 1...2 {
            if let result = try family(
                group,
                bytes: bytes,
                at: offset,
                mask: mask,
                ends: ends,
                endKey: endKey,
                budget: budget
            ) {
                return result
            }
        }
        return nil
    }

    /// 业务作用：同一上下文的整词结束规则只整理一次，未启用的嵌套符不能截断普通文字。
    /// 参数说明:
    /// - context: 当前注释或分隔符身份。
    /// - nesting: 当前明确允许的规则组。
    /// - contextEnds: 当前上下文的闭合候选。
    /// - budget: 整份词法扫描的共同工作量。
    /// 返回：可建立真实整词终点的前向候选；超量时整体失败。
    private func terminators(context: String?, nesting: UInt32, contextEnds: [String], budget: UDLScanBudget)
        throws -> [String]
    {
        var ends = contextEnds
        if nesting & 0x1000000 != 0 {
            ends += definition.lists["Operators1"] ?? []
        }
        if nesting & 0x100 != 0 {
            ends += comments[3] ?? []
        }
        if nesting & 0x200 != 0 {
            ends += comments[0] ?? []
        }
        for group in 0..<8 where nesting & (1 << group) != 0 {
            ends += delimiters[group * 3] ?? []
        }
        if context == nil {
            for action in Self.actions {
                ends += definition.lists["Folders in code1, " + action] ?? []
            }
        }
        try budget.consume(ends.count)
        return ends
    }

    /// 业务作用：同一折叠组保留起中止顺序和字面身份，整词组不能截取更长标识符。
    /// 参数说明:
    /// - group: 前向代码、整词代码或注释折叠组。
    /// - bytes: 当前完整行。
    /// - offset: 实际匹配位置。
    /// - mask: 已确认的当前嵌套权限。
    /// - ends: 当前允许终止整词的完整前向候选。
    /// - endKey: 固定上下文的结束索引身份。
    /// - budget: 本行共享继续资格。
    /// 返回：完整标记及原资源样式，不匹配时为空。
    private func family(
        _ group: Int,
        bytes: [UInt8],
        at offset: Int,
        mask: UInt32,
        ends: [String],
        endKey: String,
        budget: UDLScanBudget
    ) throws -> UDLFolderMatch? {
        let family = Self.families[group]
        for action in 0..<3 where group == 0 || mask & (family.mask << action) != 0 {
            let key = family.name + ", " + Self.actions[action]
            if let marker = try budget.longest(
                key: key,
                patterns: definition.lists[key] ?? [],
                bytes: bytes,
                offset: offset,
                ignoreCase: definition.caseIgnored
            ) {
                let end = offset + marker.utf8.count
                if group != 0 {
                    guard end < bytes.count else {
                        continue
                    }
                    if !(bytes[end] > 0 && bytes[end] < 33),
                        try budget.longest(
                            key: "fold:end:" + endKey,
                            patterns: ends,
                            bytes: bytes,
                            offset: end,
                            ignoreCase: definition.caseIgnored
                        ) == nil
                    {
                        continue
                    }
                }
                return UDLFolderMatch(
                    text: marker,
                    style: family.style,
                    action: UDLFoldAction(rawValue: action) ?? .open
                )
            }
        }
        return nil
    }
}
