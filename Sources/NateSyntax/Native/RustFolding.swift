import Foundation
import NateCore

enum RustFolding {
    private struct Row {
        let start: Int
        let end: Int
        let bytes: [UInt8]
        let classes: [UInt8]
    }

    /// 业务作用：Rust 折叠沿真实词法身份计算花括号、跨行注释和显式注释区域，不使用字符串中的标点。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 本轮固定 Rust 资源。
    /// - deadline: 词法与层级转换共用的截止。
    /// 返回：最多 65536 个完整多行范围，物理行映射到实际显示行；证据不足整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("Rust 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var row = try readRow(0, tree: tree, scanner: scanner, state: &state, budget: &budget)
        var previousStyle: UInt8 = 0
        var level = 1024
        var levels: [Int] = []
        var rows: [(start: Int, end: Int)] = []
        var headers: [Bool] = []
        while let current = row {
            let following = try readRow(
                current.end + 1,
                tree: tree,
                scanner: scanner,
                state: &state,
                budget: &budget
            )
            var next = level
            var lineComment = false
            for index in current.bytes.indices {
                try budget.consume()
                let style = current.classes[index]
                let after =
                    index + 1 < current.classes.count
                    ? current.classes[index + 1] : following?.classes.first ?? 0
                if style == 2 || style == 4 {
                    lineComment = true
                }
                if (style == 1 || style == 3), !lineComment {
                    if previousStyle != 1 && previousStyle != 3 {
                        next += 1
                    }
                    else if after != 1 && after != 3, index + 1 < current.bytes.count {
                        next -= 1
                    }
                }
                if style == 2, current.bytes[index] == 47,
                    index + 2 < current.bytes.count, current.bytes[index + 1] == 47
                {
                    if current.bytes[index + 2] == 123 {
                        next += 1
                    }
                    else if current.bytes[index + 2] == 125 {
                        next -= 1
                    }
                }
                if style == 16 {
                    if current.bytes[index] == 123 {
                        next += 1
                    }
                    else if current.bytes[index] == 125 {
                        next -= 1
                    }
                }
                previousStyle = style
            }
            guard (0...4095).contains(next) else {
                throw NateError.message("Rust 折叠层级超过完整可表示范围，正文保持可见。")
            }
            rows.append((current.start, current.end))
            levels.append(level)
            headers.append(next > level)
            level = next
            row = following
        }
        var ends = Array(repeating: rows.count - 1, count: rows.count)
        var stack: [Int] = []
        for index in rows.indices {
            try budget.consume()
            while let parent = stack.last, levels[index] <= levels[parent] {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if headers[index] {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in rows.indices where headers[index] {
            try budget.consume()
            let start = rows[index].start, end = rows[ends[index]].end
            guard end > start else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("Rust 折叠超过 65536 个范围。")
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

    /// 业务作用：折叠最多保留当前与后继两个完整物理行，跨行样式过渡拥有真实后继证据。
    /// 参数说明:
    /// - line: 当前实际逻辑行。
    /// - tree: 本轮固定正文。
    /// - scanner: 共用来源与资源的词法扫描器。
    /// - state: 前一物理范围的完整检查点。
    /// - budget: 读取、投影与折叠共用预算。
    /// 返回：有界完整物理范围与原生类别，行数之外为空，失败不隐藏任何正文。
    private static func readRow(
        _ line: Int,
        tree: PieceTree,
        scanner: SyntaxScanner,
        state: inout SyntaxState,
        budget: inout ANSILexingBudget
    ) throws -> Row? {
        guard line < tree.lineCount else {
            return nil
        }
        try budget.check()
        let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
        guard range.count <= 1_048_576 else {
            throw NateError.message("Rust 折叠涉及超过 1 MiB 的物理行。")
        }
        let source = tree.text(in: range)
        let tokens = scanner.highlight(source, base: range.lower, state: &state)
        guard state.diagnostic == nil else {
            // 未完成的字符串和注释状态不能授权隐藏后续正文。
            throw NateError.message(state.diagnostic ?? "Rust 折叠缺少完整词法证据。")
        }
        var classes = Array(repeating: UInt8(0), count: range.count)
        for token in tokens {
            guard let value = UInt8(token.lexicalStyle.dropFirst(5)) else {
                throw NateError.message("Rust 折叠缺少明确样式身份。")
            }
            for offset in token.range.lower..<token.range.upper {
                try budget.consume()
                classes[offset - range.lower] = value
            }
        }
        return Row(
            start: line,
            end: range.isEmpty ? line : tree.lineNumber(at: range.upper - 1),
            bytes: Array(source.utf8),
            classes: classes
        )
    }
}
