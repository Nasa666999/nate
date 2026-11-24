import Foundation
import NateCore

enum BashFolding {
    /// 业务作用：Bash 共享结构换行的词法与命令证据，折叠已闭合代码块、here-document 和相邻行注释。
    /// 参数说明:
    /// - snapshot: 当前窗口需要分析的完整原文快照。
    /// - deadline: 全部词法和范围处理共用的截止。
    /// 返回：最多 65536 个完整多行范围；来源容量、取消或完整层级失效时不发布部分折叠。
    static func regions(snapshot: DocumentSnapshot, deadline: ContinuousClock.Instant) throws -> [FoldRegion]
    {
        let text = snapshot.text
        guard text.lineCount <= 1_048_576, text.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("Bash 折叠超过一百万行或 64 MiB 正文容量。")
        }
        /// 业务作用：所有物理行和嵌套证据使用同一计算截止，停止后不隐藏部分正文。
        /// 参数说明: 无。
        /// 返回：仍有完整计算资格时继续；取消或过期抛错。
        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("Bash 折叠超过计算截止，原可见范围保持。")
            }
        }
        var candidates: [FoldRegion] = []
        /// 业务作用：闭合从同一真实物理行发布完整折叠范围，单行结构保留原显示。
        /// 参数说明:
        /// - start: 同一原文的实际开启行。
        /// - end: 已有明确匹配闭合的实际结束行。
        /// 返回：追加完整候选；超量时拒绝整份范围。
        func publish(_ start: Int, _ end: Int) throws {
            guard start < end else {
                return
            }
            guard candidates.count < 65_536 else {
                throw NateError.message("Bash 折叠超过 65536 个完整范围。")
            }
            candidates.append(
                FoldRegion(
                    range: ByteRange(text.lineStart(start), text.lineRange(end).upper),
                    startLine: start,
                    endLine: end,
                    level: 0
                )
            )
        }
        var lexer = BashIndentationLexer()
        var state = BashIndentationState()
        var continuation = false
        var commentStart: Int?
        for line in 0..<text.lineCount {
            try check()
            let complete = text.lineRange(line)
            // 单行过大时无法证明这行的定界含义，不能保留先前收集的部分隐藏范围。
            guard complete.count <= 1024 * 1024 else {
                throw NateError.message("Bash 折叠的单行原文超过 1 MiB。")
            }
            let row = text.lineRange(line, includeEnding: false)
            let lexed = try lexer.consume(Array(text.bytes(in: row)), line: line, check: check)
            state.beginLine(line, afterContinuation: continuation)
            continuation = lexed.continues
            if lexed.standaloneComment {
                if commentStart == nil {
                    commentStart = line
                }
            }
            else if let start = commentStart {
                try publish(start, line - 1)
                commentStart = nil
            }
            if let start = lexed.completedHereDocumentFrom {
                try publish(start, line)
            }
            for (index, token) in lexed.tokens.enumerated() {
                if index & 255 == 0 {
                    try check()
                }
                try state.consume(token, prefix: "")
                if let start = state.closedBlockFrom {
                    try publish(start, line)
                }
            }
        }
        if let start = commentStart {
            try publish(start, text.lineCount - 1)
        }
        try check()
        return candidates
    }
}
