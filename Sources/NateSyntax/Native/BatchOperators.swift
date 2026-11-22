import Foundation
import NateCore

extension BatchScanner {
    /// 业务作用：Batch 比较、管道和其它操作符分别恢复命令检查资格，引用或 caret 转义保留文字语义。
    /// 参数说明: 无。
    /// 返回：操作符或普通文字的完整范围进入本行暂存，赋值与命令位置同步推进。
    mutating func operatorWord() throws {
        let first = word(0)
        try colour(until: wordStart - 1, style: 0)
        if first == 61, word(1) == 61 {
            command = try skippedSpace(offset)
            try colour(until: wordStart + 1, style: state.processing ? 7 : 0)
            offset = wordStart + 2
        }
        else if first == 124, !(try escaped(at: wordStart)), !(try quoted(until: wordStart)) {
            command = try skippedSpace(wordStart + 1)
            try colour(until: wordStart, style: 7)
            offset = wordStart + 1
            state.processing = true
        }
        else {
            let isEscaped = try escaped(at: wordStart)
            let isQuoted = try quoted(until: wordStart)
            if [62, 41, 40, 38].contains(first), !(!state.processing && (isEscaped || isQuoted)) {
                state.processing = true
                state.unassigned = false
            }
            let style: UInt8 =
                ![41, 40].contains(first) && !isQuoted && !isEscaped
                    && !(first == 61 && !state.unassigned) ? 7 : 0
            try colour(until: wordStart, style: style)
            offset = wordStart + 1
            if first == 61, state.unassigned {
                state.unassigned = false
            }
        }
    }
}
