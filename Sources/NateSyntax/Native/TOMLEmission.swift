import Foundation
import NateCore

extension TOMLLexing {
    /// 业务作用：TOML 原生字节类别按完整 UTF-8 标量首字节投影，键名和字面不得拆开显示字符。
    /// 参数说明:
    /// - raw: 当前完整物理行的原字节。
    /// - styles: 已完整确认的逐字节原生类别。
    /// - base: 本物理行的原字节起点。
    /// - budget: 分类与展示共同的步骤和截止。
    /// 返回：最多 65536 个完整标量边界词元；超量或类别缺失时拒绝。
    static func tokens(
        raw: [UInt8],
        styles: [UInt8],
        base: Int,
        budget: inout ANSILexingBudget
    ) throws -> [TOMLCachedToken] {
        guard raw.count == styles.count else {
            throw NateError.invalidRange
        }
        var cursor = 0, output: [TOMLCachedToken] = []
        while cursor < raw.count {
            try budget.consume()
            let first = raw[cursor], style = styles[cursor]
            let width = first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
            guard width <= raw.count - cursor, style <= 15 else {
                throw NateError.invalidRange
            }
            let range = ByteRange(base + cursor, base + cursor + width)
            let kind: SyntaxKind =
                style == 1
                ? .comment
                : [9, 10, 11, 12, 13, 15].contains(style)
                    ? .string
                    : style == 4 || style == 14
                        ? .number
                        : style == 8 ? .punctuation : [3, 5, 6].contains(style) ? .keyword : .text
            if let last = output.last, last.style == style {
                output[output.count - 1] = TOMLCachedToken(
                    range: ByteRange(last.range.lower, range.upper),
                    kind: kind,
                    style: style
                )
            }
            else {
                guard output.count < 65_536 else {
                    throw NateError.message("TOML 超过 65536 个完整词元。")
                }
                output.append(
                    TOMLCachedToken(
                        range: range,
                        kind: kind,
                        style: style
                    )
                )
            }
            cursor += width
        }
        return output
    }
}
