import Foundation
import NateCore

enum TOMLFolding {
    private struct Row {
        let start: Int
        let end: Int
        let state: UInt32
    }

    /// 业务作用：TOML 折叠只采用同一完整词法得到的表头层级和注释行，统一处理上一行标记的收束。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前完整 TOML 词表与样式。
    /// - deadline: 词法与折叠共用的操作截止。
    /// 返回：最多 65536 个完整多行范围；来源、行元数据或预算不足时整份拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("TOML 折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState(), rows: [Row] = [], line = 0
        while line < tree.lineCount {
            try budget.check()
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            _ = scanner.highlight(tree.text(in: range), base: range.lower, state: &state)
            // 表头和注释行资格依赖完整词法，缺少证据时不能把正文隐藏成猜测的表格。
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "TOML 折叠缺少完整行元数据。")
            }
            let end = range.isEmpty ? line : tree.lineNumber(at: range.upper - 1)
            rows.append(
                Row(
                    start: line,
                    end: end,
                    state: state.toml.lastLineState
                )
            )
            line = end + 1
        }
        var levels: [Int] = [], previous = 1024, previousType = 0, previous2Type = 0
        var commentHead = false
        for row in rows {
            try budget.consume()
            let type = Int(row.state & 3)
            var next: Int
            if type == 2 {
                next = previous & 8192 != 0 ? (previous & 4095) + 1 : previous
                commentHead = previousType != 2
                next |= commentHead ? 8192 : 0
            }
            else {
                if type == 1 {
                    next = 1024 + Int((row.state >> 2) & 255)
                    if previousType == 2 && previous <= next {
                        commentHead = true
                        previous = next - 1
                    }
                    else if previousType == 1 && previous & 4095 >= next {
                        commentHead = true
                    }
                    next |= 8192
                }
                else if commentHead {
                    next = previous & 4095
                }
                else if previous & 8192 != 0 {
                    next = (previous & 4095) + 1
                }
                else if previousType == 2 && previous2Type == 2 {
                    next = previous - 1
                }
                else {
                    next = previous
                }
                // 相邻空表或独立注释头可能失去子行，发布之前先撤去上一行不成立的折叠标记。
                if commentHead {
                    commentHead = false
                    if !levels.isEmpty {
                        levels[levels.count - 1] = previous & 4095
                    }
                }
            }
            guard next >= 0, next & ~12_287 == 0 else {
                throw NateError.message("TOML 折叠超过完整层级范围。")
            }
            levels.append(next)
            previous = next
            previous2Type = previousType
            previousType = type
        }
        var ends = Array(repeating: rows.count - 1, count: rows.count), stack: [Int] = []
        for index in rows.indices {
            try budget.consume()
            while let parent = stack.last, levels[index] & 4095 <= levels[parent] & 4095 {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if levels[index] & 8192 != 0 {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in rows.indices where levels[index] & 8192 != 0 {
            try budget.consume()
            let start = rows[index].start, end = rows[ends[index]].end
            if end <= start {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("TOML 折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(start).lower, tree.lineRange(end).upper),
                    startLine: start,
                    endLine: end,
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
