import Foundation
import NateCore

enum RFolding {
    private struct Row {
        let start: Int
        let end: Int
        let bytes: [UInt8]
        let classes: [UInt8]
    }

    /// 业务作用：R 只按独立代码操作符的花括号形成多行折叠，字面及命名运算符不授予隐藏正文的资格。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前完整 R 资源。
    /// - deadline: 词法与折叠共用的截止。
    /// 返回：最多 65536 个完整范围，容量或来源证据不足时整份保持正文可见。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("R 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var row = try readRow(0, tree: tree, scanner: scanner, state: &state, budget: &budget)
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
            var ended = false
            for index in current.bytes.indices {
                try budget.consume()
                let byte = current.bytes[index]
                let after =
                    index + 1 < current.bytes.count
                    ? current.bytes[index + 1] : following?.bytes.first ?? 0
                if current.classes[index] == 8 {
                    if byte == 123 {
                        next += 1
                    }
                    else if byte == 125 {
                        next -= 1
                    }
                }
                if byte == 10 || byte == 13 && after != 10 {
                    ended = true
                }
            }
            guard (0...4095).contains(next) else {
                throw NateError.message("R 折叠层级超过完整可表示范围，正文保持可见。")
            }
            rows.append((current.start, current.end))
            // 原生层级只在真实物理行结束时发布，末尾未结束的行与最后空行保留默认层级。
            levels.append(ended ? level : 1024)
            headers.append(ended && next > level)
            if ended {
                level = next
            }
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
                throw NateError.message("R 折叠超过 65536 个范围。")
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

    /// 业务作用：逐行确认词法来源和类别，读取不展开整份正文，也不把未确认的后继状态用于折叠。
    /// 参数说明:
    /// - line: 当前逻辑行。
    /// - tree: 本轮固定正文树。
    /// - scanner: 共用资源和身份的扫描器。
    /// - state: 前一物理范围后的同源状态。
    /// - budget: 读取与投影共同使用的预算。
    /// 返回：有界完整物理行和类别；行数之外为空，缺少词法证据时拒绝全部折叠。
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
            throw NateError.message("R 折叠涉及超过 1 MiB 的物理行。")
        }
        let source = tree.text(in: range)
        let tokens = scanner.highlight(source, base: range.lower, state: &state)
        guard state.diagnostic == nil else {
            // 转义、反引号和原始字面状态未经确认时，后续括号不能取得折叠资格。
            throw NateError.message(state.diagnostic ?? "R 折叠缺少完整词法证据。")
        }
        var classes = Array(repeating: UInt8(0), count: range.count)
        for token in tokens {
            guard let value = UInt8(token.lexicalStyle.dropFirst(2)) else {
                throw NateError.message("R 折叠缺少明确样式身份。")
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
