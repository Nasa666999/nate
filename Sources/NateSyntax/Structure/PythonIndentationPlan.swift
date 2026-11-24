import NateCore

enum PythonIndentationPlan {
    /// 业务作用：按同一 Python 正文的逻辑行确认复合语句冒号，跨行头沿开端原空白缩进。
    /// 参数说明:
    /// - snapshot: 全部输入目标所属的完整正文。
    /// - language: 当前载入的 Python 语言资源。
    /// - ranges: 全部实际替换范围。
    /// - deadline: 本次准备和提交共用的截止。
    /// - permit: 此输入继续准备的资格。
    /// 返回：全部逐目标缩进动作；词法状态、范围、容量或执行资格不足时整批抛错。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        let text = snapshot.text
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check(deadline: deadline, permit: permit)
            byLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Python 语言缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var state = PythonIndentationState()
        var previousPrefixes: [ByteRange: String] = [:]
        var output: [ByteRange: NewlineIndentationAction] = [:]
        var consumed = 0
        for line in 0...last {
            try check(deadline: deadline, permit: permit)
            let row = text.lineRange(line)
            guard row.count <= 1_048_576, row.count <= 67_108_864 - consumed else {
                throw NateError.message("Python 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            consumed += row.count
            let source = text.text(in: row)
            let tokens = scanner.highlight(source, base: row.lower, state: &lexical)
            if let failure = lexical.diagnostic {
                // 词法传播中止后不能把余下字面内容当作新的关键字，不发布此前准备的任何目标。
                throw NateError.message(failure)
            }
            var bytes = Array(source.utf8)
            let origin = try indentation(in: bytes, base: row.lower, deadline: deadline, permit: permit)
            for token in tokens where token.isStructureOpaque {
                let replacement: UInt8 = token.kind == .comment ? 32 : 127
                for position in (token.range.lower - row.lower)..<(token.range.upper - row.lower) {
                    if position & 255 == 0 {
                        try check(deadline: deadline, permit: permit)
                    }
                    bytes[position] = replacement
                }
            }
            let physicalEnd = text.lineRange(line, includeEnding: false).upper - row.lower
            let explicitlyContinued = physicalEnd > 0 && bytes[physicalEnd - 1] == 92
            let end = explicitlyContinued ? physicalEnd - 1 : physicalEnd
            let targets = (byLine[line] ?? []).sorted {
                $0.lower < $1.lower
            }
            var lastCode: Int?
            var next = 0
            var cursor = 0
            while cursor <= end {
                if cursor & 255 == 0 {
                    try check(deadline: deadline, permit: permit)
                }
                while next < targets.count && targets[next].lower - row.lower <= cursor {
                    if next & 255 == 0 {
                        try check(deadline: deadline, permit: permit)
                    }
                    let target = targets[next]
                    // 光标位于一个还没有完整消费的词内部时不可沿其后面的冒号取得缩进资格。
                    if target.lower - row.lower == cursor, !explicitlyContinued || cursor < end,
                        let header = state.completed
                    {
                        if state.requiresLineBoundary {
                            if lastCode == nil {
                                lastCode =
                                    bytes[..<end].lastIndex(where: { $0 != 9 && $0 != 12 && $0 != 32 }) ?? -1
                            }
                            if target.upper - row.lower <= (lastCode ?? -1) {
                                output[target] = .inherit
                                next += 1
                                continue
                            }
                        }
                        if header == origin.range {
                            output[target] = .increase
                        }
                        else {
                            let prefix = previousPrefixes[header] ?? text.text(in: header)
                            previousPrefixes[header] = prefix
                            output[target] = .align(prefix: prefix, levels: 1)
                        }
                    }
                    else {
                        output[target] = .inherit
                    }
                    next += 1
                }
                guard cursor < end else {
                    break
                }
                let byte = bytes[cursor]
                if byte == 58, cursor + 1 < end, bytes[cursor + 1] == 61 {
                    // 赋值表达式的 `:=` 是一个完整运算符，光标位于两字节之间时也不能成为语句头冒号。
                    try state.byte(61, origin: origin)
                    cursor += 2
                }
                else if PythonIndentationState.isWordStart(byte) {
                    let start = cursor
                    cursor += 1
                    while cursor < end && PythonIndentationState.isWordPart(bytes[cursor]) {
                        if cursor & 255 == 0 {
                            try check(deadline: deadline, permit: permit)
                        }
                        cursor += 1
                    }
                    let word =
                        cursor - start <= 12 ? String(decoding: bytes[start..<cursor], as: UTF8.self) : ""
                    let separated = cursor == end || [9, 12, 32].contains(bytes[cursor])
                    state.word(word, softKeywordSeparated: separated, origin: origin)
                }
                else {
                    try state.byte(byte, origin: origin)
                    cursor += 1
                }
            }
            while next < targets.count {
                output[targets[next]] = .inherit
                next += 1
            }
            try state.endLine(
                continuing: explicitlyContinued || lexical.python.literal != nil
                    || !lexical.python.expressions.isEmpty
            )
        }
        try check(deadline: deadline, permit: permit)
        return output
    }

    /// 业务作用：Python 块归属按语言的八列 Tab 判定，最终插入仍保留源前缀并使用编辑器配置。
    /// 参数说明:
    /// - bytes: 当前行未遮蔽的实际原字节。
    /// - base: 当前物理行在正文中的字节起点。
    /// - deadline: 全部目标共用的截止。
    /// - permit: 当前仍有准备资格的检查。
    /// 返回：可复用的原始空白范围及 Python 语法列。
    private static func indentation(
        in bytes: [UInt8],
        base: Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> PythonIndentationOrigin {
        var end = 0
        var column = 0
        while end < bytes.count && (bytes[end] == 32 || bytes[end] == 9) {
            if end & 255 == 0 {
                try check(deadline: deadline, permit: permit)
            }
            column += bytes[end] == 9 ? 8 - column % 8 : 1
            end += 1
        }
        return PythonIndentationOrigin(range: ByteRange(base, base + end), column: column)
    }

    /// 业务作用：前缀、词法和目标使用同一取消与截止权限，失效后不保留部分动作。
    /// 参数说明:
    /// - deadline: 本次全部换行的共同截止。
    /// - permit: 当前输入继续准备的资格。
    /// 返回：仍然有效时正常返回，否则抛错。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("Python 语言缩进已失效或超过共同截止。")
        }
    }
}
