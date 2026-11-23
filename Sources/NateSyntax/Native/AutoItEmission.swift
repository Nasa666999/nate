import Foundation
import NateCore

extension AutoItLexing {
    /// 业务作用：AutoIt 原生字节类别按完整 UTF-8 标量首字节投影，变量、注释及字面不得拆开显示字符。
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
    ) throws -> [AutoItCachedToken] {
        guard raw.count == styles.count else {
            throw NateError.invalidRange
        }
        var cursor = 0, output: [AutoItCachedToken] = []
        while cursor < raw.count {
            try budget.consume()
            let first = raw[cursor], style = styles[cursor]
            let width = first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
            guard width <= raw.count - cursor, style <= 14 else {
                throw NateError.invalidRange
            }
            let range = ByteRange(base + cursor, base + cursor + width)
            let kind: SyntaxKind =
                [1, 2].contains(style)
                ? .comment
                : [7, 10].contains(style)
                    ? .string
                    : style == 3
                        ? .number
                        : [4, 5, 6, 11, 13].contains(style)
                            ? .keyword
                            : style == 8
                                ? .punctuation
                                : style == 12 ? .tag : .text
            if let last = output.last, last.style == style {
                output[output.count - 1] = AutoItCachedToken(
                    range: ByteRange(last.range.lower, range.upper),
                    kind: kind,
                    style: style
                )
            }
            else {
                guard output.count < 65_536 else {
                    throw NateError.message("AutoIt 超过 65536 个完整词元。")
                }
                output.append(
                    AutoItCachedToken(
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
