import Foundation
import NateCore

public struct UDLContext: Sendable, Equatable {
    var style: String
    var ends: [String]
    var escapes: [String]
    var lineOnly: Bool
    var continues: [String] = []
    var ruleGroup = 0

    /// 业务作用：同一样式的不同开端具有各自的起止与转义证据，不能共用另一位置的匹配索引。
    /// 参数说明: 无。
    /// 返回：当前原始样式与对应位置组成的稳定规则身份。
    var ruleKey: String {
        style + ":group:" + String(ruleGroup)
    }
}

public struct UDLState: Sendable, Equatable {
    var contexts: [UDLContext] = []
    var ruleGeneration: UUID?
    var atLineStart = true
    var hasVisible = false
    var foldWhite = true
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
        state.foldWhite = true
        try budget.consume(bytes.count)
        let commentRules = try UDLForwardRules(words: definition.lists["Comments"] ?? [], budget: budget)
        let delimiterRules = try UDLForwardRules(words: definition.lists["Delimiters"] ?? [], budget: budget)
        let comments = commentRules.flattened
        let delimiters = delimiterRules.flattened
        let numbers = try UDLNumberRules(definition: definition, budget: budget)
        var folders = UDLFoldRules(definition: definition)
        var numberEnds: [String: Set<UInt8>] = [:]
        var numberBlocked: [String: Int] = [:]
        var tokens: [SyntaxToken] = []
        var backwardStart = true
        var i = 0
        while i < bytes.count {
            try budget.consume()
            guard tokens.count <= 65_536 else {
                throw NateError.message("UDL 单行词法片段超过 65536 个。")
            }
            let start = i
            var forwardBoundary = false
            var compactForward = false
            defer {
                UDLPhysicalLine.advance(bytes[start..<i], state: &state)
                if i > start {
                    backwardStart = forwardBoundary || bytes[i - 1] > 0 && bytes[i - 1] < 33
                    // 前向符号消费后观察真实后继；已跳过的起止文字不再被当作普通正文重复计入紧凑层级。
                    if compactForward {
                        if i == bytes.count || bytes[i] == 0 || bytes[i] >= 33 {
                            state.foldWhite = false
                        }
                    }
                    else if bytes[start..<i].contains(where: {
                        $0 == 0 || $0 >= 33
                    }) {
                        state.foldWhite = false
                    }
                }
            }
            let context = state.contexts.last
            let nesting =
                context.map {
                    definition.styles[$0.style]?.nesting ?? 0
                } ?? UInt32.max
            if let context,
                let escape = try budget.longest(
                    key: context.ruleKey + ":escape",
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
                    key: context.ruleKey + ":end",
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
                forwardBoundary = true
                compactForward = context.style != "LINE COMMENTS"
                continue
            }
            if let context, context.lineOnly, bytes[i] == 10 || bytes[i] == 13 {
                if context.style == "LINE COMMENTS" {
                    let continued = try UDLPhysicalLine.continues(
                        bytes: bytes,
                        before: i,
                        patterns: context.continues,
                        ignoreCase: definition.caseIgnored,
                        budget: budget
                    )
                    if !continued {
                        state.contexts.removeLast()
                    }
                    i += bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 ? 2 : 1
                    emit(
                        &tokens,
                        start: base + start,
                        end: base + i,
                        style: context.style,
                        definition: definition
                    )
                    continue
                }
                else {
                    state.contexts.removeLast()
                    continue
                }
            }
            var entered = false
            if nesting & 0x100 != 0,
                let opener = try commentRules.match(
                    field: 3,
                    key: "Comments3",
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored,
                    budget: budget
                )
            {
                state.contexts.append(
                    UDLContext(
                        style: "COMMENTS",
                        ends: commentRules.patterns(field: 4, group: opener.group),
                        escapes: [],
                        lineOnly: false,
                        ruleGroup: opener.group
                    )
                )
                i += opener.text.utf8.count
                entered = true
                compactForward = true
            }
            else if nesting & 0x200 != 0,
                UDLPhysicalLine.permits(
                    definition.lineCommentPosition,
                    atLineStart: state.atLineStart,
                    hasVisible: state.hasVisible
                ),
                let opener = try commentRules.match(
                    field: 0,
                    key: "Comments0",
                    bytes: bytes,
                    offset: i,
                    ignoreCase: definition.caseIgnored,
                    budget: budget
                )
            {
                state.contexts.append(
                    UDLContext(
                        style: "LINE COMMENTS",
                        ends: commentRules.patterns(field: 2, group: opener.group),
                        escapes: [],
                        lineOnly: true,
                        continues: commentRules.patterns(field: 1, group: opener.group),
                        ruleGroup: opener.group
                    )
                )
                i += opener.text.utf8.count
                entered = true
            }
            else {
                for group in 0..<8 where nesting & (1 << group) != 0 {
                    if let opener = try delimiterRules.match(
                        field: group * 3,
                        key: "Delimiter\(group)",
                        bytes: bytes,
                        offset: i,
                        ignoreCase: definition.caseIgnored,
                        budget: budget
                    ) {
                        let ends = delimiterRules.patterns(field: group * 3 + 2, group: opener.group)
                        state.contexts.append(
                            UDLContext(
                                style: "DELIMITERS\(group + 1)",
                                ends: ends,
                                escapes: delimiterRules.patterns(field: group * 3 + 1, group: opener.group),
                                lineOnly: false,
                                ruleGroup: opener.group
                            )
                        )
                        i += opener.text.utf8.count
                        entered = true
                        compactForward = true
                        break
                    }
                }
            }
            if entered {
                forwardBoundary = true
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
                let identity = context?.ruleKey ?? "DEFAULT"
                let key = context?.style ?? "DEFAULT"
                var ends: Set<UInt8>
                if let existing = numberEnds[key] {
                    ends = existing
                }
                else {
                    ends = try numbers.terminators(
                        definition: definition,
                        comments: comments,
                        delimiters: delimiters,
                        nesting: nesting,
                        contextEnds: [],
                        budget: budget
                    )
                    numberEnds[key] = ends
                }
                // 通用结束外观按样式共享，当前位置的闭合证据只在本次数值判断中补入，避免逐位置复制整份规则。
                for marker in context?.ends ?? [] {
                    try budget.consume()
                    if let byte = marker.utf8.first, byte != 0 {
                        ends.insert(byte)
                        if definition.caseIgnored, (65...90).contains(byte) {
                            ends.insert(byte + 32)
                        }
                        else if definition.caseIgnored, (97...122).contains(byte) {
                            ends.insert(byte - 32)
                        }
                    }
                }
                if i >= numberBlocked[identity, default: 0] {
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
                    numberBlocked[identity] = try UDLNumberRules.failedEnd(
                        in: bytes,
                        from: i,
                        ends: ends,
                        budget: budget
                    )
                }
            }
            var matched = false
            if let folder = try folders.match(
                bytes: bytes,
                offset: i,
                context: context?.ruleKey,
                nesting: nesting,
                wordStart: backwardStart,
                contextEnds: context?.ends ?? [],
                comments: comments,
                delimiters: delimiters,
                budget: budget
            ) {
                i += folder.text.utf8.count
                forwardBoundary = folder.style == "FOLDER IN CODE1"
                compactForward = forwardBoundary
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: folder.style,
                    definition: definition,
                    merge: false,
                    foldMarker: SyntaxFoldMarker(
                        action: folder.action,
                        insideComment: context?.style.contains("COMMENT") == true
                    )
                )
                continue
            }
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
                        forwardBoundary = group == 1
                        compactForward = forwardBoundary
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
        guard tokens.count <= 65_536 else {
            throw NateError.message("UDL 单行词法片段超过 65536 个。")
        }
        return tokens
    }

    /// 业务作用：连续相同样式合并输出，避免按字节生成大量呈现对象。
    /// 参数说明:
    /// - tokens: 已生成范围。
    /// - start: 新片段起点。
    /// - end: 新片段结束。
    /// - style: 资源样式名。
    /// - definition: 完整 UDL。
    /// - merge: 是否合并相邻相同样式，折叠标记须保留各自独立的完整边界。
    /// - foldMarker: 当前独立标记的明确结构身份。
    /// 返回：追加或合并呈现，不改正文。
    static func emit(
        _ tokens: inout [SyntaxToken],
        start: Int,
        end: Int,
        style: String,
        definition: UDLDefinition,
        merge: Bool = true,
        foldMarker: SyntaxFoldMarker? = nil
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
        if merge, let previous = tokens.last, previous.range.upper == start, previous.kind == kind,
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
                lexicalStyle: lexicalStyle,
                foldMarker: foldMarker
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
