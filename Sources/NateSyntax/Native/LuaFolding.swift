import Foundation
import NateCore

enum LuaFolding {
    private struct Row {
        let start: Int
        let end: Int
        let bytes: [UInt8]
        let classes: [UInt8]
    }

    /// 业务作用：Lua 以明确关键字、圆括号和花括号及长字面边界建立折叠，普通字符串不授予结构权限。
    /// 参数说明:
    /// - snapshot: 本轮固定的完整正文。
    /// - language: 具有完整词表与样式的 Lua 定义。
    /// - deadline: 词法和折叠共用的截止。
    /// 返回：最多 65536 个完整范围；来源或预算不足时整份保持正文可见。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("Lua 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var row = try readRow(0, tree: tree, scanner: scanner, state: &state, budget: &budget)
        var level = 1024
        var previousStyle: UInt8 = 0
        var rows: [(start: Int, end: Int)] = []
        var levels: [Int] = []
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
            var visible = false
            var ended = false
            for index in current.bytes.indices {
                try budget.consume()
                let byte = current.bytes[index]
                let style = current.classes[index]
                let nextByte =
                    index + 1 < current.bytes.count
                    ? current.bytes[index + 1] : following?.bytes.first ?? 0
                let nextStyle =
                    index + 1 < current.classes.count
                    ? current.classes[index + 1] : following?.classes.first ?? style
                if style == 5, previousStyle != 5, [105, 100, 102, 101, 114, 117].contains(byte) {
                    var end = index
                    while end < min(current.bytes.count, index + 9), Self.word(current.bytes[end]) {
                        end += 1
                    }
                    let word = String(decoding: current.bytes[index..<end], as: UTF8.self)
                    if ["if", "do", "function", "repeat"].contains(word) {
                        next += 1
                    }
                    else if word == "end" || word == "until" {
                        next -= 1
                    }
                }
                else if style == 10 {
                    if byte == 123 || byte == 40 {
                        next += 1
                    }
                    else if byte == 125 || byte == 41 {
                        next -= 1
                    }
                }
                else if style == 8 || style == 1 {
                    if previousStyle != style {
                        next += 1
                    }
                    else if nextStyle != style {
                        next -= 1
                    }
                }
                if byte == 10 || byte == 13 && nextByte != 10 {
                    ended = true
                }
                if !LuaLexing.space(byte) {
                    visible = true
                }
                previousStyle = style
            }
            guard (0...4095).contains(next) else {
                throw NateError.message("Lua 折叠层级超过完整可表示范围，正文保持可见。")
            }
            rows.append((current.start, current.end))
            levels.append(level)
            headers.append(ended && visible && next > level)
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
                throw NateError.message("Lua 折叠超过 65536 个范围。")
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

    /// 业务作用：折叠关键字采用固定 ASCII 边界，不能把较长名称的开端解释成代码块。
    /// 参数说明:
    /// - byte: 原始名称字节。
    /// 返回：ASCII 字母、数字或下划线为真。
    private static func word(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：逐物理行取得同源完整类别，跨行字面只从已确认缓存投影，不展开整份正文。
    /// 参数说明:
    /// - line: 当前真实行。
    /// - tree: 固定正文树。
    /// - scanner: 共用来源与规则的扫描器。
    /// - state: 前一范围后的连续状态。
    /// - budget: 读取和投影共同使用的预算。
    /// 返回：完整有界物理行；超过行数为空，词法证据不足时拒绝全部折叠。
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
            throw NateError.message("Lua 折叠涉及超过 1 MiB 的物理行。")
        }
        let source = tree.text(in: range)
        let tokens = scanner.highlight(source, base: range.lower, state: &state)
        guard state.diagnostic == nil else {
            // 未确认的长字面或延续状态不能授权隐藏后续正文。
            throw NateError.message(state.diagnostic ?? "Lua 折叠缺少完整词法证据。")
        }
        var classes = Array(repeating: UInt8(0), count: range.count)
        for token in tokens {
            guard let style = UInt8(token.lexicalStyle.dropFirst(4)) else {
                throw NateError.message("Lua 折叠缺少明确样式身份。")
            }
            for offset in token.range.lower..<token.range.upper {
                try budget.consume()
                classes[offset - range.lower] = style
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
