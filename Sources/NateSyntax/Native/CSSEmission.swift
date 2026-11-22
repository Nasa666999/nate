import Foundation
import NateCore

extension CSSScanner {
    /// 业务作用：封闭词法段以完整原字节范围保留原生身份，不为显示缓存复制可变样式对象。
    /// 参数说明:
    /// - end: 当前缓冲区中已经完整确认的结束边界。
    /// - style: 当前完整段的原生类别。
    /// 返回：最多 65536 个合并相邻类别的词元；范围、样式或容量不足时拒绝整批结果。
    mutating func emit(until end: Int, style: UInt8) throws {
        guard end >= emitted, end <= bytes.count, rules.styles[String(style)] != nil else {
            throw NateError.message("CSS 词元缺少完整范围或样式。")
        }
        if end == emitted {
            return
        }
        try budget.consume()
        let kind: SyntaxKind
        switch style {
        case 9:
            kind = .comment
        case 13, 14:
            kind = .string
        case 5:
            kind = .punctuation
        case 0, 8, 16:
            kind = .text
        default:
            kind = .keyword
        }
        var lower = base + emitted
        if let previous = tokens.last, previous.style == style, previous.range.upper == lower {
            lower = previous.range.lower
            tokens.removeLast()
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("CSS 完整分类超过 65536 个词元。")
        }
        tokens.append(
            CSSCachedToken(
                range: ByteRange(lower, base + end),
                kind: kind,
                style: style
            )
        )
        emitted = end
    }
}
