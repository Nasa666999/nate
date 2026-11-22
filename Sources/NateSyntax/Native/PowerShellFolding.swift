import Foundation
import NateCore

enum PowerShellFolding {
    private struct Row {
        let start: Int
        let end: Int
        let bytes: [UInt8]
        let classes: [UInt8]
    }

    /// 业务作用：PowerShell 按真实操作符花括号、块注释与明确 region 注释建立多行折叠。
    /// 参数说明:
    /// - snapshot: 本轮完整不可变正文。
    /// - language: 当前固定 PowerShell 资源。
    /// - deadline: 词法与折叠共用的截止。
    /// 返回：最多 65536 个完整多行范围，来源或容量不足时整体保留正文可见。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("PowerShell 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var row = try readRow(0, tree: tree, scanner: scanner, state: &state, budget: &budget)
        var previous: UInt8 = 0
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
            for index in current.bytes.indices {
                try budget.consume()
                let style = current.classes[index]
                let after =
                    index + 1 < current.classes.count
                    ? current.classes[index + 1] : following?.classes.first ?? 0
                let byte = current.bytes[index]
                if style == 6 {
                    if byte == 123 {
                        next += 1
                    }
                    else if byte == 125 {
                        next -= 1
                    }
                }
                else if style == 13 {
                    if previous != 13 && previous != 16 {
                        next += 1
                    }
                    else if after != 13 && after != 16 {
                        next -= 1
                    }
                }
                else if style == 1, byte == 35 {
                    var start = index + 1
                    while start < current.bytes.count,
                        current.bytes[start] == 32 || current.bytes[start] == 9
                    {
                        try budget.consume()
                        start += 1
                    }
                    if current.bytes[start...].starts(with: "region".utf8) {
                        next += 1
                    }
                    else if current.bytes[start...].starts(with: "endregion".utf8) {
                        next -= 1
                    }
                }
                previous = style
            }
            guard (0...4095).contains(next) else {
                throw NateError.message("PowerShell 折叠层级超过完整可表示范围，正文保持可见。")
            }
            rows.append((current.start, current.end))
            // 原生折叠只发布含原字节的行，末尾空行保留默认层级，不能延长未闭合范围。
            levels.append(current.bytes.isEmpty ? 1024 : level)
            headers.append(!current.bytes.isEmpty && next > level)
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
                throw NateError.message("PowerShell 折叠超过 65536 个范围。")
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

    /// 业务作用：当前与后继完整物理行提供块注释过渡证据，不展开整份正文。
    /// 参数说明:
    /// - line: 当前实际逻辑行。
    /// - tree: 本轮固定正文。
    /// - scanner: 共用资源与来源的扫描器。
    /// - state: 前一物理范围的完整状态。
    /// - budget: 读取、投影与折叠共用的预算。
    /// 返回：有界原字节与原生类别，行数之外为空；词法证据不足时拒绝整份折叠。
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
            throw NateError.message("PowerShell 折叠涉及超过 1 MiB 的物理行。")
        }
        let source = tree.text(in: range)
        let tokens = scanner.highlight(source, base: range.lower, state: &state)
        guard state.diagnostic == nil else {
            // 未确认的 here-string 和注释状态不能授权隐藏后续正文。
            throw NateError.message(state.diagnostic ?? "PowerShell 折叠缺少完整词法证据。")
        }
        var classes = Array(repeating: UInt8(0), count: range.count)
        for token in tokens {
            guard let value = UInt8(token.lexicalStyle.dropFirst(11)) else {
                throw NateError.message("PowerShell 折叠缺少明确样式身份。")
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
