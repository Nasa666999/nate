import Foundation
import NateCore

extension BatchLexing {
    /// 业务作用：Batch 仅转换 ASCII 大写候选，Unicode、NUL 和原文展示字节保持独立。
    /// 参数说明:
    /// - raw: 当前完整物理行的原字节。
    /// - budget: 所属操作的共同步骤和截止。
    /// 返回：长度相同的 ASCII 小写候选行，超预算则拒绝。
    static func lower(_ raw: [UInt8], budget: inout ANSILexingBudget) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(raw.count)
        for byte in raw {
            try budget.consume()
            output.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return output
    }

    /// 业务作用：Batch 原生字节类别按完整 UTF-8 标量首字节投影，标签和变量不得拆开显示字符。
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
    ) throws -> [BatchCachedToken] {
        guard raw.count == styles.count else {
            throw NateError.invalidRange
        }
        var cursor = 0, output: [BatchCachedToken] = []
        while cursor < raw.count {
            try budget.consume()
            let first = raw[cursor], style = styles[cursor]
            let width = first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
            guard width <= raw.count - cursor, style <= 8 else {
                throw NateError.invalidRange
            }
            let range = ByteRange(base + cursor, base + cursor + width)
            let kind: SyntaxKind =
                [1, 8].contains(style)
                ? .comment
                : style == 2 || style == 5 ? .keyword : style == 7 ? .punctuation : .text
            if let last = output.last, last.style == style {
                output[output.count - 1] = BatchCachedToken(
                    range: ByteRange(last.range.lower, range.upper),
                    kind: kind,
                    style: style
                )
            }
            else {
                guard output.count < 65_536 else {
                    throw NateError.message("Batch 超过 65536 个完整词元。")
                }
                output.append(
                    BatchCachedToken(
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
