import Foundation
import NateCore

extension ASMLexing {
    /// 业务作用：汇编 原生字节类别按完整 UTF-8 标量首字节投影，指令、注释及字面不得拆开显示字符。
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
    ) throws -> [ASMCachedToken] {
        guard raw.count == styles.count else {
            throw NateError.invalidRange
        }
        var cursor = 0, output: [ASMCachedToken] = []
        while cursor < raw.count {
            try budget.consume()
            let first = raw[cursor], style = styles[cursor]
            let width = first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
            guard width <= raw.count - cursor, style <= 16 else {
                throw NateError.invalidRange
            }
            let range = ByteRange(base + cursor, base + cursor + width)
            let kind: SyntaxKind =
                [1, 11, 15].contains(style)
                ? .comment
                : [3, 12, 13, 16].contains(style)
                    ? .string
                    : [6, 7, 8, 9, 10, 14].contains(style)
                        ? .keyword
                        : style == 2
                            ? .number
                            : style == 4 ? .punctuation : .text
            if let last = output.last, last.style == style {
                output[output.count - 1] = ASMCachedToken(
                    range: ByteRange(last.range.lower, range.upper),
                    kind: kind,
                    style: style
                )
            }
            else {
                guard output.count < 65_536 else {
                    throw NateError.message("汇编 超过 65536 个完整词元。")
                }
                output.append(
                    ASMCachedToken(
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
