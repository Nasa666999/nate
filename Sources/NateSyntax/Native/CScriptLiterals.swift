import Foundation
import NateCore

extension CLexing {
    /// 业务作用：真实文件末尾的独立反斜杠按原生续接阶段消费，不把显示片段边界冒充文件末尾。
    /// 参数说明:
    /// - offset: 当前范围内的原字节位置。
    /// 返回：当前脚本范围真实结束且该位置为末尾反斜杠时为真。
    func scriptTerminalSplice(at offset: Int) -> Bool {
        scriptRules != nil && offset >= 0 && offset == bytes.count - 1 && bytes[offset] == 92
            && (snapshot.map {
                base + bytes.count == $0.text.byteCount
            } ?? true)
    }

    /// 业务作用：末尾续接沿当前明确类别着色，已被前一转义消费的反斜杠不能再次取得续接资格。
    /// 参数说明: 无。
    /// 返回：当前末尾反斜杠已消费时为真，其它位置仍使用普通读取流程。
    mutating func consumeScriptTerminalSplice() throws -> Bool {
        guard scriptTerminalSplice(at: cursor), !(state.quote != nil && state.escape),
            !(state.regex && state.regexEscape)
        else {
            return false
        }
        let kind: SyntaxKind
        let style: String
        if state.blockComment || state.lineComment {
            kind = .comment
            style = commentStyle
        }
        else if state.preprocessor {
            kind = .keyword
            style = "preprocessor"
        }
        else if state.quote != nil {
            kind = .string
            style = state.quote == 39 ? "character" : "string"
        }
        else if state.regex && !state.regexFlags {
            kind = .string
            style = "regex"
        }
        else if state.splicedWord || state.continuedWord {
            kind = .text
            style = "identifier"
        }
        else if state.continuedNumber {
            kind = .number
            style = state.numberUserLiteral ? "userLiteral" : "number"
        }
        else if tokens.last?.range.upper == base + cursor,
            tokens.last?.lexicalStyle == "script:10"
        {
            kind = .punctuation
            style = "punctuation"
        }
        else {
            kind = .text
            style = "text"
        }
        try emit(cursor, cursor + 1, kind: kind, style: style, updatesContext: false)
        cursor += 1
        skippedScriptEnd = true
        return true
    }

    /// 业务作用：脚本共享词法的名称后继不包含美元号，美元号只在下一名称的首位取得独立资格。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：原生名称内部成员为真，美元号保持下一名称边界。
    static func scriptWordPart(_ byte: UInt8) -> Bool {
        wordPart(byte) && byte != 36
    }

    /// 业务作用：已闭合普通引号紧邻用户后缀时按完整原生字面重新分类，字面正文仍保持结构不透明。
    /// 参数说明: 无。
    /// 返回：完整后缀及本行字面已消费时为真；其它共享语言与无后缀引号保留原流程。
    mutating func scriptQuotedSuffix() throws -> Bool {
        guard scriptRules != nil, cursor + 1 < bytes.count, bytes[cursor + 1] == 95 else {
            return false
        }
        var end = cursor + 2
        while end < bytes.count, Self.scriptWordPart(bytes[end]) || bytes[end] == 46 {
            try budget.consume()
            end += 1
        }
        _ = try reclassifyScriptLiteral("userLiteral")
        try emit(cursor, end, kind: .string, style: "userLiteral")
        cursor = end
        state.quote = nil
        state.escape = false
        state.escapeDigits = 0
        state.escapeRadix = nil
        state.continuedNumber =
            cursor < bytes.count
            && (spliceWidth(at: cursor) > 0 || scriptTerminalSplice(at: cursor))
        state.numberUserLiteral = state.continuedNumber
        return true
    }
}
