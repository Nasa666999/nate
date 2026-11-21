import Foundation
import NateCore

enum CFolding {
    private struct Row {
        let start: Int
        let end: Int
        let level: Int
        let header: Bool
    }

    /// 业务作用：C 与 C++ 共用语法括号、块注释及预处理区域的真实层级，条件分支保留全部正文。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 已固定的 C 或 C++ 语言资源。
    /// - deadline: 本轮折叠的共同截止。
    /// 返回：至多 65536 个含子行的有界范围；词法、容量、取消或时间证据不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("C/C++ 折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var rows: [Row] = []
        var line = 0
        var level = 1024
        var streamComment = false
        while line < tree.lineCount {
            try budget.check()
            let requested = tree.lineRange(line)
            if requested.isEmpty {
                rows.append(
                    Row(
                        start: line,
                        end: line,
                        level: level,
                        header: false
                    )
                )
                break
            }
            let range = try ANSILexing.physicalRange(requested, tree: tree, budget: &budget)
            guard range.count <= 1_048_576 else {
                throw NateError.message("C/C++ 折叠涉及超过 1 MiB 的物理行。")
            }
            let source = tree.text(in: range)
            let before = state.c
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 词法未完成时不能把字符串、注释或宏体中的标点用于隐藏正文。
                throw NateError.message(state.diagnostic ?? "C/C++ 折叠缺少完整词法状态。")
            }
            let bytes = Array(source.utf8)
            let startsContinuation = bytes.count >= 2 && bytes[0] == 92 && [10, 13].contains(bytes[1])
            // 词法在首个普通字节才解除旧行注释，折叠不能把待交接标志误当成本行已生效的注释。
            let lineComment =
                before.lineComment
                && (!before.lineStartPending || before.continuationLine || startsContinuation)
            var analysis = CFoldingLine(
                bytes: bytes,
                base: range.lower,
                tokens: tokens,
                blockComment: before.blockComment,
                lineComment: lineComment,
                preprocessor: before.preprocessor,
                streamComment: streamComment,
                blockStar: before.blockStar,
                budget: budget
            )
            let next = level + (try analysis.delta())
            budget = analysis.budget
            streamComment = analysis.streamComment
            let end = tree.lineNumber(at: range.upper - 1)
            rows.append(
                Row(
                    start: line,
                    end: end,
                    level: level,
                    header: next > level
                )
            )
            level = next
            line = end + 1
        }
        var stack: [Int] = []
        var ends = Array(repeating: rows.count - 1, count: rows.count)
        for index in rows.indices {
            try budget.consume()
            while let parent = stack.last, rows[index].level <= rows[parent].level {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if rows[index].header {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in rows.indices where rows[index].header {
            try budget.consume()
            let first = rows[index].start
            let last = rows[ends[index]].end
            guard last > first else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("C/C++ 折叠超过 65536 个范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(first).lower, tree.lineRange(last).upper),
                    startLine: first,
                    endLine: last,
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
