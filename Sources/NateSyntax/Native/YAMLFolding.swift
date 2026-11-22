import Foundation
import NateCore

enum YAMLFolding {
    private struct Row {
        let indent: Int
        let white: Bool
        let comment: Bool
        var encoded: Int {
            indent + 1024 | (white ? 4096 : 0)
        }
    }

    /// 业务作用：YAML 按真实缩进归属空行及行首注释，不把块文本或映射值按代码括号折叠。
    /// 参数说明:
    /// - snapshot: 本轮完整不可变正文。
    /// - language: 当前固定 YAML 资源。
    /// - deadline: 词法、缩进与范围整理共用的截止。
    /// 返回：至多 65536 个完整多行范围；容量、来源或执行资格不足时整体保留可见正文。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("YAML 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var rows: [Row] = []
        for line in 0..<tree.lineCount {
            try budget.check()
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("YAML 折叠涉及超过 1 MiB 的物理行。")
            }
            let source = tree.text(in: range)
            _ = scanner.highlight(source, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 缺少完整词法证据时不能把未知块文本缩进作为隐藏后续正文的权限。
                throw NateError.message(state.diagnostic ?? "YAML 折叠缺少完整词法状态。")
            }
            let bytes = Array(source.utf8)
            var cursor = 0
            var indent = 0
            while cursor < bytes.count, bytes[cursor] == 32 || bytes[cursor] == 9 {
                try budget.consume()
                indent = bytes[cursor] == 32 ? indent + 1 : (indent / 8 + 1) * 8
                guard indent <= 3070 else {
                    throw NateError.message("YAML 折叠缩进超过 3070 列，正文保持可见。")
                }
                cursor += 1
            }
            let first = cursor < bytes.count ? bytes[cursor] : 0
            rows.append(
                Row(
                    indent: indent,
                    white: range.isEmpty || [32, 9, 10, 13].contains(first),
                    comment: bytes.first == 35
                )
            )
        }
        let last = tree.lineNumber(at: max(0, tree.byteCount - 1))
        var levels = Array(repeating: 1024, count: rows.count)
        var current = 0
        var indentation = rows[0].encoded
        while current <= last {
            try budget.consume()
            var next = current + 1
            var following = next <= last ? rows[next].encoded : indentation
            let currentLevel = indentation & 4095
            var level = indentation
            if following & 4096 != 0 {
                following = 4096 | currentLevel
            }
            while next < last, following & 4096 != 0 || rows[next].comment {
                try budget.consume()
                next += 1
                following = rows[next].encoded
            }
            let after = following & 4095
            let before = max(currentLevel, after)
            var skipped = next - 1
            var skipLevel = after
            while skipped > current {
                try budget.consume()
                if rows[skipped].encoded & 4095 > after {
                    skipLevel = before
                }
                levels[skipped] = skipLevel | (rows[skipped].white ? 4096 : 0)
                skipped -= 1
            }
            if indentation & 4096 == 0, currentLevel < after {
                level |= 8192
            }
            levels[current] = level
            indentation = following
            current = next
        }
        var ends = Array(repeating: rows.count - 1, count: rows.count)
        var stack: [Int] = []
        for line in rows.indices {
            try budget.consume()
            while let parent = stack.last, levels[line] & 4095 <= levels[parent] & 4095 {
                ends[parent] = line - 1
                stack.removeLast()
            }
            if levels[line] & 8192 != 0 {
                stack.append(line)
            }
        }
        var output: [FoldRegion] = []
        for line in rows.indices where levels[line] & 8192 != 0 && ends[line] > line {
            try budget.consume()
            guard output.count < 65_536 else {
                throw NateError.message("YAML 折叠超过 65536 个范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(line).lower, tree.lineRange(ends[line]).upper),
                    startLine: line,
                    endLine: ends[line],
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
