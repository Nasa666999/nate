import Foundation
import NateCore

public struct UDLContext: Sendable, Equatable {
    var style: String
    var ends: [String]
    var escapes: [String]
    var lineOnly: Bool
}

public struct UDLState: Sendable, Equatable {
    var contexts: [UDLContext] = []
    var ruleGeneration: UUID?
    public fileprivate(set) var diagnostic: String?

    /// 业务作用：建立独立 UDL 行首状态，供跨行分隔符和注释传播。
    /// 参数说明: 无。
    /// 返回：中性词法状态。
    public init() {}
}

public enum UDLLexer {
    /// 业务作用：按 UDL 字面规则与 nesting 权限执行，不将规则改写成通用正则。
    /// 参数说明:
    /// - text: 连续文本片段。
    /// - base: 文档内字节起点。
    /// - definition: 已校验完整 UDL。
    /// - state: 安全边界处的跨行状态。
    /// - deadline: 所属分析的共同截止，省略时本行仍至多五秒。
    /// - permit: 整份分析继续准备的资格。
    /// 返回：完整样式与上下文一次发布；取消、容量或规则代次不符时保留原上下文并记录原因。
    public static func highlight(
        _ text: String,
        base: Int,
        definition: UDLDefinition,
        state: inout UDLState,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        let budget = UDLScanBudget(deadline: deadline, permit: permit)
        do {
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.contexts.count <= 128,
                state.ruleGeneration == nil || state.ruleGeneration == definition.generation
            else {
                throw NateError.message("UDL 行范围、嵌套容量或规则代次不一致。")
            }
            try budget.validate(definition)
            var candidate = state
            let tokens = try scan(text, base: base, definition: definition, state: &candidate, budget: budget)
            try budget.check()
            candidate.ruleGeneration = definition.generation
            state = candidate
            return tokens
        }
        catch {
            // 先保留完整旧上下文再报告失败，不能截去较早开端或发布已完成的部分样式。
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：在独立候选状态内执行全部字面规则，成功前不改动调用方的有效行首状态。
    /// 参数说明:
    /// - text: 当前完整物理行或明确连续片段。
    /// - base: 原文起点。
    /// - definition: 本次固定规则代次。
    /// - state: 仅本次扫描使用的候选状态。
    /// - budget: 规则索引、匹配及输出共用的预算。
    /// 返回：全部范围和上下文完整时返回样式，否则抛错并由入口保留旧状态。
    private static func scan(
        _ text: String,
        base: Int,
        definition: UDLDefinition,
        state: inout UDLState,
        budget: UDLScanBudget
    ) throws -> [SyntaxToken] {
        let bytes = Array(text.utf8)
        let comments = indexed(definition.lists["Comments"] ?? [])
        let delimiters = indexed(definition.lists["Delimiters"] ?? [])
        let numbers = try UDLNumberRules(definition: definition, budget: budget)
        var numberEnds: [String: Set<UInt8>] = [:]
        var numberBlocked: [String: Int] = [:]
        var tokens: [SyntaxToken] = []
        var i = 0
        while i < bytes.count {
            try budget.consume()
            guard tokens.count <= 65_536 else {
                throw NateError.message("UDL 单行词法片段超过 65536 个。")
            }
            let start = i
            let context = state.contexts.last
            let nesting =
                context.flatMap {
                    definition.styles[$0.style]?.nesting
                } ?? UInt32.max
            if let context,
                let escape = try budget.longest(
                    key: context.style + ":escape",
                    patterns: context.escapes,
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                i = min(bytes.count, i + escape.utf8.count)
                if i < bytes.count {
                    i += 1
                    while i < bytes.count && bytes[i] & 0xC0 == 0x80 {
                        i += 1
                    }
                }
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: context.style,
                    definition: definition
                )
                continue
            }
            if let context,
                let end = try budget.longest(
                    key: context.style + ":end",
                    patterns: context.ends,
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                i += end.utf8.count
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: context.style,
                    definition: definition
                )
                state.contexts.removeLast()
                continue
            }
            if let context, context.lineOnly, bytes[i] == 10 || bytes[i] == 13 {
                state.contexts.removeLast()
                continue
            }
            var entered = false
            if nesting & 0x100 != 0,
                let opener = try budget.longest(
                    key: "Comments3",
                    patterns: comments[3] ?? [],
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                state.contexts.append(
                    UDLContext(style: "COMMENTS", ends: comments[4] ?? [], escapes: [], lineOnly: false)
                )
                i += opener.utf8.count
                entered = true
            }
            else if nesting & 0x200 != 0,
                let opener = try budget.longest(
                    key: "Comments0",
                    patterns: comments[0] ?? [],
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                state.contexts.append(
                    UDLContext(
                        style: "LINE COMMENTS",
                        ends: (comments[2] ?? []).filter {
                            $0 != "EOL" && $0 != "((EOL))"
                        },
                        escapes: comments[1] ?? [],
                        lineOnly: true
                    )
                )
                i += opener.utf8.count
                entered = true
            }
            else {
                for group in 0..<8 where nesting & (1 << group) != 0 {
                    if let opener = try budget.longest(
                        key: "Delimiter\(group)",
                        patterns: delimiters[group * 3] ?? [],
                        bytes: bytes,
                        offset: i,
                        ignoreCase: definition.caseIgnored
                    ) {
                        let ends = delimiters[group * 3 + 2] ?? []
                        state.contexts.append(
                            UDLContext(
                                style: "DELIMITERS\(group + 1)",
                                ends: ends.filter {
                                    $0 != "EOL" && $0 != "((EOL))"
                                },
                                escapes: delimiters[group * 3 + 1] ?? [],
                                lineOnly: ends.contains("EOL") || ends.contains("((EOL))")
                            )
                        )
                        i += opener.utf8.count
                        entered = true
                        break
                    }
                }
            }
            if entered {
                if state.contexts.count > 128 {
                    throw NateError.message("UDL 嵌套超过 128 层，原上下文保留。")
                }
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: state.contexts.last?.style ?? "DEFAULT",
                    definition: definition
                )
                continue
            }
            if nesting & 0x4000000 != 0, i == 0 || !word(bytes[i - 1]) {
                let key = context?.style ?? "DEFAULT"
                let ends: Set<UInt8>
                if let existing = numberEnds[key] {
                    ends = existing
                }
                else {
                    ends = try numbers.terminators(
                        definition: definition,
                        comments: comments,
                        delimiters: delimiters,
                        nesting: nesting,
                        contextEnds: context?.ends ?? [],
                        budget: budget
                    )
                    numberEnds[key] = ends
                }
                if i >= numberBlocked[key, default: 0] {
                    let candidate = UDLNumberScanner(
                        rules: numbers,
                        bytes: bytes,
                        start: i,
                        ends: ends,
                        budget: budget
                    )
                    if let length = try candidate.length() {
                        i += length
                        emit(
                            &tokens,
                            start: base + start,
                            end: base + i,
                            style: "NUMBERS",
                            definition: definition
                        )
                        continue
                    }
                    numberBlocked[key] = try UDLNumberRules.failedEnd(
                        in: bytes,
                        from: i,
                        ends: ends,
                        budget: budget
                    )
                }
            }
            var matched = false
            for group in 1...8 where nesting & (1 << (group + 9)) != 0 {
                if i == 0 || !word(bytes[i - 1]),
                    let keyword = try budget.longest(
                        key: "Keywords\(group)",
                        patterns: definition.lists["Keywords\(group)"] ?? [],
                        bytes: bytes,
                        offset: i,
                        ignoreCase: definition.caseIgnored
                    )
                {
                    let end = i + keyword.utf8.count
                    if definition.prefix.contains(group) || end == bytes.count || !word(bytes[end]) {
                        i = end
                        emit(
                            &tokens,
                            start: base + start,
                            end: base + i,
                            style: "KEYWORDS\(group)",
                            definition: definition
                        )
                        matched = true
                        break
                    }
                }
            }
            if matched {
                continue
            }
            for group in 1...2 where nesting & (group == 1 ? 0x1000000 : 0x2000000) != 0 {
                if let op = try budget.longest(
                    key: "Operators\(group)",
                    patterns: definition.lists["Operators\(group)"] ?? [],
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored
                ) {
                    let end = i + op.utf8.count
                    if group == 1
                        || (i == 0 || !word(bytes[i - 1])) && (end == bytes.count || !word(bytes[end]))
                    {
                        i = end
                        emit(
                            &tokens,
                            start: base + start,
                            end: base + i,
                            style: "OPERATORS",
                            definition: definition
                        )
                        matched = true
                        break
                    }
                }
            }
            if matched {
                continue
            }
            i += 1
            while i < bytes.count && bytes[i] & 0xC0 == 0x80 {
                i += 1
            }
            emit(
                &tokens,
                start: base + start,
                end: base + i,
                style: context?.style ?? "DEFAULT",
                definition: definition
            )
        }
        state.contexts.removeAll {
            $0.lineOnly
        }
        guard tokens.count <= 65_536 else {
            throw NateError.message("UDL 单行词法片段超过 65536 个。")
        }
        return tokens
    }

    /// 业务作用：解析 UDL 的两位字段编号，编号用于规则组而不是字符码。
    /// 参数说明:
    /// - words: 原始有序规则。
    /// 返回：同一编号的多个候选标记。
    static func indexed(_ words: [String]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        for word in words {
            if let index = Int(word.prefix(2)), word.count > 2 {
                result[index, default: []].append(String(word.dropFirst(2)))
            }
        }
        return result
    }

    /// 业务作用：连续相同样式合并输出，避免按字节生成大量呈现对象。
    /// 参数说明:
    /// - tokens: 已生成范围。
    /// - start: 新片段起点。
    /// - end: 新片段结束。
    /// - style: 资源样式名。
    /// - definition: 完整 UDL。
    /// 返回：追加或合并呈现，不改正文。
    static func emit(
        _ tokens: inout [SyntaxToken],
        start: Int,
        end: Int,
        style: String,
        definition: UDLDefinition
    ) {
        let rule = definition.styles[style]
        let lexicalStyle = "udl:" + style
        let kind: SyntaxKind =
            style == "DEFAULT"
            ? .text
            : style.contains("COMMENT")
                ? .comment
                : style.contains("DELIMITER")
                    ? .string
                    : style == "NUMBERS" ? .number : style.hasPrefix("KEYWORDS") ? .keyword : .punctuation
        var start = start
        if let previous = tokens.last, previous.range.upper == start, previous.kind == kind,
            previous.lexicalStyle == lexicalStyle,
            previous.foreground == rule?.foreground, previous.background == rule?.background,
            previous.fontStyle == rule?.fontStyle ?? 0
        {
            start = previous.range.lower
            tokens.removeLast()
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(start, end),
                kind: kind,
                foreground: rule?.foreground,
                background: rule?.background,
                fontStyle: rule?.fontStyle ?? 0,
                lexicalStyle: lexicalStyle
            )
        )
    }

    /// 业务作用：规则边界按标识符字节判断，不切开 UTF-8。
    /// 参数说明:
    /// - byte: 邻接字节。
    /// 返回：可构成词的字节。
    static func word(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
            || byte >= 128
    }
}
