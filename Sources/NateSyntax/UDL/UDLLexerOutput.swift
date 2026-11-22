import Foundation
import NateCore

extension UDLLexer {
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
