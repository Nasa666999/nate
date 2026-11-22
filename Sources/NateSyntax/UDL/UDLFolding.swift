import Foundation
import NateCore

enum UDLFolding {
    private struct Line {
        var level: Int
        var next: Int
        let empty: Bool
    }

    /// 业务作用：在同一完整正文和 UDL 词法上下文上建立行层级，折叠标记、注释分组与空白规则共用来源证据。
    /// 参数说明:
    /// - snapshot: 本次固定文档及修订。
    /// - definition: 当前完整 UDL 规则代次。
    /// - deadline: 词法传播和范围转换共用的截止。
    /// 返回：至多 65536 个完整非空多行范围；取消、词法失败或容量不足时不提供部分隐藏结构。
    static func regions(
        snapshot: DocumentSnapshot,
        definition: UDLDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        guard snapshot.text.byteCount <= 67_108_864, snapshot.text.lineCount <= 1_048_576 else {
            throw NateError.message("UDL 折叠超过 64 MiB 或一百万物理行。")
        }
        var state = UDLState()
        var rows: [Line] = []
        var level = 0
        var commentBlock = false
        var previousComment = false
        for line in 0..<snapshot.text.lineCount {
            try check(deadline)
            let range = snapshot.text.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("UDL 折叠单行超过 1 MiB。")
            }
            let text = snapshot.text.text(in: range)
            let continuedLine = state.contexts.last?.style == "LINE COMMENTS"
            let tokens = UDLLexer.highlight(
                text,
                base: range.lower,
                definition: definition,
                state: &state,
                deadline: deadline
            )
            if let diagnostic = state.diagnostic {
                // 缺少后续词法证据时不能把余下原文当成普通代码隐藏，保留全部行可见。
                throw NateError.message(diagnostic)
            }
            var minimum = level, next = level
            for token in tokens {
                if let action = token.foldMarker?.action {
                    switch action {
                    case .open:
                        minimum = min(minimum, next)
                        next += 1
                    case .middle:
                        next = max(0, next - 1)
                        minimum = min(minimum, next)
                        next += 1
                    case .close:
                        next = max(0, next - 1)
                    }
                    guard next <= 65_536 else {
                        throw NateError.message("UDL 折叠层级超过 65536。")
                    }
                }
            }
            let bytes = Array(text.utf8)
            var tokenIndex = 0, pureComment = true, sawComment = false
            for index in bytes.indices {
                if index & 255 == 0 {
                    try check(deadline)
                }
                let position = range.lower + index
                while tokenIndex < tokens.count, tokens[tokenIndex].range.upper <= position {
                    tokenIndex += 1
                }
                let token = tokenIndex < tokens.count ? tokens[tokenIndex] : nil
                let comment = token?.kind == .comment && token?.foldMarker?.insideComment != false
                if comment {
                    sawComment = true
                }
                if bytes[index] == 0 || bytes[index] >= 33 {
                    if !comment {
                        pureComment = false
                    }
                }
            }
            // 续行末端不构成新的独立行注释；保留词法样式不代表取得注释分组的起始资格。
            let commentEligible = !continuedLine || state.contexts.last?.style == "LINE COMMENTS"
            let comment =
                definition.allowFoldOfComments && pureComment && sawComment && level == next
                && commentEligible
            if definition.allowFoldOfComments {
                if commentBlock, !comment, previousComment {
                    next = max(0, next - 1)
                    if let previous = rows.indices.last {
                        rows[previous].next = next
                    }
                    minimum = max(0, minimum - 1)
                    commentBlock = false
                }
                if !commentBlock, comment, previousComment, let previous = rows.indices.last {
                    next += 1
                    rows[previous].next = next
                    minimum = next
                    commentBlock = true
                }
            }
            rows.append(
                Line(
                    level: minimum,
                    next: next,
                    empty: state.foldWhite
                )
            )
            previousComment = comment
            level = next
        }
        return try convert(rows, snapshot: snapshot, compact: definition.foldCompact, deadline: deadline)
    }

    /// 业务作用：用单次逆向栈找到每个标题的真实结束行，密集嵌套不逐标题重新扫描剩余文件。
    /// 参数说明:
    /// - rows: 完整词法传播后的实际行层级。
    /// - snapshot: 同一固定正文。
    /// - compact: 是否让明确空行随前一折叠范围收起。
    /// - deadline: 整份分析的共同截止。
    /// 返回：来源边界内的完整多行范围，超量或取消时整体失败。
    private static func convert(
        _ rows: [Line],
        snapshot: DocumentSnapshot,
        compact: Bool,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        var stack: [Int] = []
        var boundaries = Array(repeating: rows.count, count: rows.count)
        for line in rows.indices.reversed() {
            if line & 255 == 0 {
                try check(deadline)
            }
            while let next = stack.last, rows[next].level > rows[line].level || compact && rows[next].empty {
                stack.removeLast()
            }
            boundaries[line] = stack.last ?? rows.count
            stack.append(line)
        }
        var output: [FoldRegion] = []
        for line in rows.indices where rows[line].level < rows[line].next {
            try check(deadline)
            let end = boundaries[line] - 1
            guard end > line else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("UDL 折叠范围超过 65536 个。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(snapshot.text.lineStart(line), snapshot.text.lineRange(end).upper),
                    startLine: line,
                    endLine: end,
                    level: 0
                )
            )
        }
        try check(deadline)
        return output
    }

    /// 业务作用：词法、注释分组和范围转换沿同一截止响应取消，不让完成配对后的整理重新获得执行时间。
    /// 参数说明:
    /// - deadline: 本次完整折叠的共同截止。
    /// 返回：任务仍有效时继续，取消或超时明确失败。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("UDL 折叠已取消或超过共同截止。")
        }
    }
}
