import Foundation
import NateCore

enum RubyIndentationPlan {
    /// 业务作用：在同一固定 Ruby 正文上准备整次多光标换行，原块和字面使用连续物理行证据。
    /// 参数说明:
    /// - snapshot: 本次全部替换位置所属的开头和正文。
    /// - ranges: 原生或内核已经复验的所有真实替换范围。
    /// - deadline: 词法准备、选择定位和最终提交共用的实际截止。
    /// - permit: 当前编辑仍有继续资格的检查。
    /// 返回：所有位置有界的缩进动作；范围、容量、取消和超时不允许部分提交。
    static func actions(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：保证整个结构读取和任何目标都使用同一次输入的权威。
        /// 参数说明: 无。
        /// 返回：操作仍有效时继续，取消和失去共同截止时整批失败。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Ruby 结构缩进已取消或超过共同截止。")
            }
        }

        let text = snapshot.text
        var targets: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            targets[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = targets.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Ruby 结构缩进的前置传播超过一百万行。")
        }
        var bytesRemaining = 64 * 1_048_576
        var prefixesRemaining = 1_048_576
        var lexer = RubyIndentationLexer()
        var structure = RubyIndentationState()
        var result: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let raw = text.lineRange(line, includeEnding: false)
            let length = text.lineRange(line).count
            // 切片前须确认整体输入容量，任何超量位置都会阻止先前目标的动作发布。
            guard length <= 1_048_576, length <= bytesRemaining else {
                throw NateError.message("Ruby 结构缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            bytesRemaining -= length
            let bytes = text.bytes(in: raw)
            let row = try lexer.row(bytes, check: check)
            let ordered = (targets[line] ?? []).sorted {
                $0.lower < $1.lower
            }
            if row.entirelyOpaque {
                for range in ordered {
                    try check()
                    result[range] = .inherit
                }
                continue
            }
            let rawPrefix = bytes.prefix {
                $0 == 9 || $0 == 32
            }
            guard rawPrefix.count <= prefixesRemaining else {
                throw NateError.message("Ruby 结构缩进的原水平前缀超过 1 MiB。")
            }
            prefixesRemaining -= rawPrefix.count
            let prefix = String(decoding: rawPrefix, as: UTF8.self)
            structure.beginLine()
            var current = 0
            for range in ordered {
                try check()
                let offset = min(raw.count, range.lower - raw.lower)
                while current < row.tokens.count, row.tokens[current].span.upper <= offset {
                    try check()
                    try structure.consume(row.tokens[current], prefix: prefix)
                    current += 1
                }
                // 在原词中间、正文以外的块回退或未结束字面时，已消费的外层结构没有改写当前缩进的权限。
                guard !(row.beginsInLiteral && offset == 0), !(row.holdsLiteral && offset == raw.count),
                    current == row.tokens.count || row.tokens[current].span.lower >= offset,
                    row.commentStart.map({
                        offset <= $0 || offset == raw.count
                    }) != false
                else {
                    result[range] = .inherit
                    continue
                }
                let next = following(row.tokens, at: range.upper - raw.lower)
                result[range] = structure.action(before: next)
            }
            while current < row.tokens.count {
                try check()
                try structure.consume(row.tokens[current], prefix: prefix)
                current += 1
            }
            structure.finishLine(opaque: row.holdsLiteral)
        }
        try check()
        return result
    }

    /// 业务作用：核对替换后保留的第一个完整词，终点切开一个原词时不能借用更远的闭合。
    /// 参数说明:
    /// - tokens: 当前物理行按原字节递增的完整代码词元。
    /// - offset: 当前实际替换的相对结束字节。
    /// 返回：存在紧邻且完整的实际后继时返回该原词。
    private static func following(_ tokens: [RubyIndentationLexer.Token], at offset: Int)
        -> RubyIndentationLexer.Token?
    {
        var lower = 0
        var upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].span.upper <= offset {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < tokens.count, tokens[lower].span.lower >= offset else {
            return nil
        }
        return tokens[lower]
    }
}
