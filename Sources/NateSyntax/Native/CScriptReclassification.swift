import Foundation
import NateCore

extension CLexing {
    /// 业务作用：当前脚本字面可从已合并片段中独立重新分类，前一个已闭合字面不继承后一个字面的错误或后缀。
    /// 参数说明:
    /// - style: 当前完整字面取得的原生身份。
    /// 返回：脚本当前字面已经完整重分类时为真；其它共享语言保留原有流程。
    mutating func reclassifyScriptLiteral(_ style: String) throws -> Bool {
        guard scriptRules != nil else {
            return false
        }
        let lower = base + literalStart
        var output: [SyntaxToken] = []
        output.reserveCapacity(tokens.count)
        for token in tokens {
            try budget.consume()
            guard token.kind == .string, token.range.upper > lower else {
                try appendScriptToken(token, to: &output)
                continue
            }
            if token.range.lower < lower {
                try appendScriptToken(
                    SyntaxToken(
                        range: ByteRange(token.range.lower, lower),
                        kind: token.kind,
                        foreground: token.foreground,
                        background: token.background,
                        fontStyle: token.fontStyle,
                        lexicalStyle: token.lexicalStyle
                    ),
                    to: &output
                )
            }
            try appendScriptToken(
                makeToken(
                    range: ByteRange(max(lower, token.range.lower), token.range.upper),
                    kind: .string,
                    style: style
                ),
                to: &output
            )
        }
        tokens = output
        return true
    }

    /// 业务作用：重分类后的相邻同类范围统一合并，拆分新增类别仍遵守完整词元上限。
    /// 参数说明:
    /// - token: 已经确认原字节与资源的片段。
    /// - output: 本轮尚未发布的完整输出。
    /// 返回：片段完整追加或合并，超过 65536 个真实类别范围时抛错。
    private func appendScriptToken(_ token: SyntaxToken, to output: inout [SyntaxToken]) throws {
        if let previous = output.last, previous.range.upper == token.range.lower,
            previous.kind == token.kind, previous.lexicalStyle == token.lexicalStyle
        {
            output[output.count - 1] = SyntaxToken(
                range: ByteRange(previous.range.lower, token.range.upper),
                kind: token.kind,
                foreground: token.foreground,
                background: token.background,
                fontStyle: token.fontStyle,
                lexicalStyle: token.lexicalStyle
            )
            return
        }
        guard output.count < 65_536 else {
            throw NateError.message("脚本重分类超过 65536 个完整词元。")
        }
        output.append(token)
    }
}
