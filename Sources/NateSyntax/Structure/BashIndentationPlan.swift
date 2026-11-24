import Foundation
import NateCore

enum BashIndentationPlan {
    /// 业务作用：为全部真实换行位置准备同源 Bash 结构缩进，正文、词法和先前开端使用同一固定快照。
    /// 参数说明:
    /// - snapshot: 所有光标共同使用的完整原文。
    /// - ranges: 已归并并经过字节边界复验的完整目标。
    /// - deadline: 准备与最终编辑共用的截止。
    /// - permit: 当前编辑事务继续准备的资格。
    /// 返回：一次发布的逐位置动作；容量、取消或范围失败时不产生可部分提交的结果。
    static func actions(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：让行传播、词元和全部换行位置共用编辑动作的截止和继续资格。
        /// 参数说明: 无。
        /// 返回：资格继续有效时通过，否则停止整次结构换行准备。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Bash 语言缩进已取消或超过共同截止，正文和选区保持原状。")
            }
        }
        let text = snapshot.text
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            byLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Bash 语言缩进的前置传播超过一百万行。")
        }
        var lexer = BashIndentationLexer()
        var state = BashIndentationState()
        var continuation = false
        var remainingBytes = 64 * 1024 * 1024
        var remainingPrefixes = 1024 * 1024
        var result: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let complete = text.lineRange(line)
            let row = text.lineRange(line, includeEnding: false)
            // 先核对原字节容量，再读正文和构造词元，不让超量输入造成半次多光标编辑。
            guard complete.count <= 1024 * 1024, complete.count <= remainingBytes else {
                throw NateError.message("Bash 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remainingBytes -= complete.count
            let bytes = Array(text.bytes(in: row))
            let lexed = try lexer.consume(bytes, line: line, check: check)
            let targets = (byLine[line] ?? []).sorted { $0.lower < $1.lower }
            state.beginLine(line, afterContinuation: continuation)
            continuation = lexed.continues
            if lexed.hereDocument {
                for range in targets {
                    try check()
                    result[range] = .inherit
                }
                continue
            }
            let indentation = bytes.prefix(while: { $0 == 9 || $0 == 32 })
            guard indentation.count <= remainingPrefixes else {
                throw NateError.message("Bash 结构换行读取的原始缩进超过 1 MiB。")
            }
            remainingPrefixes -= indentation.count
            let prefix = String(decoding: indentation, as: UTF8.self)
            let tokens = lexed.tokens
            var index = 0
            for range in targets {
                try check()
                let offset = min(bytes.count, range.lower - row.lower)
                while index < tokens.count && tokens[index].upper <= offset {
                    try check()
                    try state.consume(tokens[index], prefix: prefix)
                    index += 1
                }
                // 插入点跨过引号开端或仍在不完整替换中时，已读取的外层块也不能改写这段字面缩进。
                if (lexed.startsInLiteral && offset == 0)
                    || (lexed.holdsLiteral && offset == bytes.count)
                    || (index < tokens.count && tokens[index].opaque && tokens[index].lower < offset)
                {
                    result[range] = .inherit
                    continue
                }
                let next = following(tokens, startingAt: range.upper - row.lower)
                result[range] = state.action(before: next)
            }
            while index < tokens.count {
                try check()
                try state.consume(tokens[index], prefix: prefix)
                index += 1
            }
        }
        try check()
        return result
    }

    /// 业务作用：寻找紧随选择的真实原词，替换终点落在另一个词内时禁止借用更远的闭合。
    /// 参数说明:
    /// - tokens: 当前物理行按原字节递增的词元。
    /// - offset: 替换后的既有后继字节偏移。
    /// 返回：能沿当前行取得的完整词或操作符，越过行尾、引号或词内部时为空。
    private static func following(_ tokens: [BashIndentationToken], startingAt offset: Int)
        -> BashIndentationToken?
    {
        var lower = 0
        var upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].lower < offset {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < tokens.count, lower == 0 || tokens[lower - 1].upper <= offset else {
            return nil
        }
        return tokens[lower]
    }
}
