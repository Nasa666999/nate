import Foundation
import NateCore

extension CLexing {
    /// 业务作用：主要与次要关键字共享稳定词元边界，前缀 @ 名称保持独立身份，预处理名称只在井号后解释。
    /// 参数说明: 无。
    /// 返回：推进一个完整原始标识符，并保留其代码或预处理身份。
    mutating func word() throws {
        let wasContinued = state.continuedWord
        let start = cursor
        if bytes[cursor] == 64 {
            cursor += 1
        }
        while cursor < bytes.count, Self.wordPart(bytes[cursor]) {
            try budget.consume()
            cursor += 1
        }
        let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
        let continues = cursor < bytes.count ? spliceWidth(at: cursor) > 0 : unicodeLineEnding
        state.continuedWord = cursor == bytes.count && unicodeLineEnding
        state.splicedWord = cursor < bytes.count && spliceWidth(at: cursor) > 0
        if state.directiveWord {
            if value.utf8.count <= 64 - state.directivePrefix.utf8.count {
                state.directivePrefix += value
            }
            else {
                state.directivePrefix = ""
                state.directiveWord = false
            }
            if !continues {
                state.directiveWord = false
                state.expectsHeader = ["include", "include_next", "import", "embed"].contains(
                    state.directivePrefix
                )
                state.directivePrefix = ""
            }
        }
        else {
            state.expectsHeader = false
        }
        let style =
            wasContinued || continues
            ? "identifier"
            : (keywords.contains(value)
                ? "keyword" : (secondaryKeywords.contains(value) ? "type" : "identifier"))
        try emitCode(start, cursor, kind: style == "identifier" ? .text : .keyword, style: style)
    }

    /// 业务作用：按词法候选保留数值及用户后缀范围，不使用浮点转换截断大整数或猜测编译器类型。
    /// 参数说明: 无。
    /// 返回：推进完整候选；格式是否合法仍由实际编译器判断。
    mutating func number() throws {
        let start = cursor
        var userLiteral = state.continuedNumber && state.numberUserLiteral
        while cursor < bytes.count {
            let byte = bytes[cursor]
            let exponentSign =
                cursor > start && [69, 101, 80, 112].contains(bytes[cursor - 1]) && [43, 45].contains(byte)
            guard Self.wordPart(byte) || byte == 46 || byte == 39 || exponentSign else {
                break
            }
            try budget.consume()
            if byte == 95 {
                userLiteral = true
            }
            cursor += 1
        }
        state.continuedNumber = cursor < bytes.count ? spliceWidth(at: cursor) > 0 : unicodeLineEnding
        state.numberUserLiteral = state.continuedNumber && userLiteral
        try emitCode(start, cursor, kind: .number, style: userLiteral ? "userLiteral" : "number")
    }

    /// 业务作用：数值续行保留原身份，名称只在非 C 换行的 Unicode 分段之间延续，新物理行重新分类。
    /// 参数说明: 无。
    /// 返回：消费当前延续分片时为真；遇到实际词元分隔符时收回旧延续状态。
    mutating func continueToken() throws -> Bool {
        let byte = bytes[cursor]
        if state.continuedWord {
            if Self.wordPart(byte) {
                try word()
                return true
            }
            state.continuedWord = false
        }
        if state.continuedNumber {
            if Self.wordPart(byte) || byte == 46 || byte == 39 {
                try number()
                return true
            }
            state.continuedNumber = false
            state.numberUserLiteral = false
        }
        return false
    }

    /// 业务作用：代码标识符采用与共享 C 词法相同的原字节候选，Unicode 内容不被当成单字节标点拆开。
    /// 参数说明:
    /// - byte: 当前原始字节。
    /// 返回：ASCII 字母、下划线、扩展美元标识符和非 ASCII 字节可以开始候选。
    static func wordStart(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95 || byte == 36 || byte >= 128
    }

    /// 业务作用：标识符中允许数字延续，点号仍独立于名称，数值候选另行处理。
    /// 参数说明:
    /// - byte: 当前原始字节。
    /// 返回：可以延续同一个完整名称候选时为真。
    static func wordPart(_ byte: UInt8) -> Bool {
        wordStart(byte) || byte >= 48 && byte <= 57
    }

    /// 业务作用：宏体标点属于预处理范围，不能冒充主代码块的结构标点。
    /// 参数说明:
    /// - start: 行内起点。
    /// - end: 行内结束边界。
    /// - kind: 普通代码中的基础分类。
    /// - style: 普通代码中的独立词法样式。
    /// - updatesContext: 是否推进实际代码前文，物理续行保留此前身份。
    /// 返回：当前预处理体使用一致的独立身份，其它代码保持自身类别。
    mutating func emitCode(
        _ start: Int,
        _ end: Int,
        kind: SyntaxKind,
        style: String,
        updatesContext: Bool = true
    ) throws {
        try emit(
            start,
            end,
            kind: state.preprocessor ? .keyword : kind,
            style: state.preprocessor ? "preprocessor" : style,
            updatesContext: updatesContext
        )
    }

    /// 业务作用：逻辑续行保留当前注释、字符串或宏体身份，不把被移除的结束符视为新的代码行。
    /// 参数说明:
    /// - start: 完整续行序列起点。
    /// - end: 完整续行序列结束边界。
    /// 返回：在原字节坐标中呈现原上下文，不更改状态。
    mutating func emitContext(_ start: Int, _ end: Int) throws {
        if state.blockComment || state.lineComment {
            try emit(start, end, kind: .comment, style: commentStyle, updatesContext: false)
        }
        else if state.regex {
            try emit(start, end, kind: .string, style: "regex", updatesContext: false)
        }
        else if state.quote != nil || state.header {
            try emit(
                start,
                end,
                kind: .string,
                style: state.header ? "header" : (state.quote == 39 ? "character" : "string"),
                updatesContext: false
            )
        }
        else if state.continuedNumber {
            try emitCode(
                start,
                end,
                kind: .number,
                style: state.numberUserLiteral ? "userLiteral" : "number",
                updatesContext: false
            )
        }
        else if state.continuedWord || state.splicedWord {
            try emitCode(start, end, kind: .text, style: "identifier", updatesContext: false)
        }
        else {
            try emitCode(
                start,
                end,
                kind: state.operatorPending ? .punctuation : .text,
                style: state.operatorPending ? "punctuation" : "continuation",
                updatesContext: false
            )
        }
    }

    /// 业务作用：记录后续正则起点证据并合并连续同类范围，整行片段与原字节坐标始终受固定容量保护。
    /// 参数说明:
    /// - start: 当前行内起点。
    /// - end: 当前行内结束边界。
    /// - kind: 基础呈现类别。
    /// - style: C 词法命名空间中的独立身份。
    /// - updatesContext: 是否从已消费字节推进正则起点和原始前后缀判断。
    /// 返回：完整范围加入有限列表；超量抛错，调用方不得发布半行结果。
    mutating func emit(_ start: Int, _ end: Int, kind: SyntaxKind, style: String, updatesContext: Bool = true)
        throws
    {
        guard end > start else {
            return
        }
        if updatesContext {
            // 默认与注释样式不贡献前置字符，原文中的未分类反斜线不能遮掉此前有效标点。
            var needsVisible = kind != .comment && style != "text" && style != "continuation"
            var needsAdd = true
            for offset in (start..<end).reversed() {
                try budget.consume()
                let byte = bytes[offset]
                if needsVisible, ![9, 10, 11, 12, 13, 32].contains(byte) {
                    state.previousNonWhite = byte
                    needsVisible = false
                }
                if needsAdd, byte == 43 || byte == 45 {
                    let previous =
                        offset > 0
                        ? bytes[offset - 1] : snapshot?.text.byte(at: base - 1) ?? state.lastRawByte
                    state.lastAddWasDoubled = previous == byte
                    needsAdd = false
                }
                if !needsVisible, !needsAdd {
                    break
                }
            }
        }
        let identity = "c:" + style
        if let last = tokens.last, last.range.upper == base + start, last.kind == kind,
            last.lexicalStyle == identity
        {
            tokens[tokens.count - 1] = SyntaxToken(
                range: ByteRange(last.range.lower, base + end),
                kind: kind,
                lexicalStyle: identity
            )
            return
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("C/C++ 高亮暂停：单行词法片段超过 65536 个。")
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(base + start, base + end),
                kind: kind,
                lexicalStyle: identity
            )
        )
    }
}
