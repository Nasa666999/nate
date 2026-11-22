import Foundation
import NateCore

enum ObjCFolding {
    private struct Row {
        let start: Int
        let end: Int
        let bytes: [UInt8]
        let classes: [UInt8]
    }

    /// 业务作用：Objective-C 按独立指令、预处理、普通注释花括号及流式注释边界建立多行折叠。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前独立语言资源。
    /// - deadline: 读取、词法与折叠共用的截止。
    /// 返回：最多 65536 个完整范围，容量或词法证据不足时整份保持正文可见。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("Objective-C 折叠超过正文或行数预算。")
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
            var unindent = 0
            var visible = 0
            var ended = false
            for index in current.bytes.indices {
                try budget.consume()
                let byte = current.bytes[index]
                let afterByte =
                    index + 1 < current.bytes.count ? current.bytes[index + 1] : following?.bytes.first ?? 0
                let eol = byte == 10 || byte == 13 && afterByte != 10
                let style = current.classes[index]
                let afterStyle =
                    index + 1 < current.classes.count
                    ? current.classes[index + 1] : following?.classes.first ?? 0
                if streamComment(style) {
                    if !streamComment(previous) {
                        next += 1
                    }
                    else if !streamComment(afterStyle), !eol {
                        next -= 1
                    }
                }
                if style == 9, byte == 35 {
                    var start = index + 1
                    while start < current.bytes.count, current.bytes[start] == 32 || current.bytes[start] == 9
                    {
                        try budget.consume()
                        start += 1
                    }
                    if current.bytes[start...].starts(with: "region".utf8)
                        || current.bytes[start...].starts(with: "if".utf8)
                    {
                        next += 1
                    }
                    else if current.bytes[start...].starts(with: "end".utf8) {
                        next -= 1
                    }
                }
                if style == 10 || style == 1 || style == 2 {
                    if byte == 123 {
                        next += 1
                        if next == level {
                            unindent = rows.isEmpty ? 1 : -1
                        }
                    }
                    else if byte == 125 {
                        next -= 1
                    }
                }
                if style == 20, byte == 64 {
                    let suffix = current.bytes[(index + 1)...]
                    if suffix.starts(with: "interface".utf8) || suffix.starts(with: "implementation".utf8)
                        || suffix.starts(with: "protocol".utf8)
                    {
                        next += 1
                    }
                    else if suffix.starts(with: "end".utf8) {
                        next -= 1
                    }
                }
                if eol {
                    if unindent < 0 {
                        level += unindent
                    }
                    else {
                        next += unindent
                    }
                    ended = true
                }
                if !ObjCLexing.space(byte) {
                    visible += 1
                }
                previous = style
            }
            guard (0...4095).contains(level), (0...4095).contains(next) else {
                throw NateError.message("Objective-C 折叠层级超过可表示范围，正文保持可见。")
            }
            rows.append((current.start, current.end))
            levels.append(level)
            // 原生折叠只在真实物理行结束时确认标题，末尾未结束的行保留进入该行前的层级。
            headers.append(ended && visible > 0 && next > level)
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
                throw NateError.message("Objective-C 折叠超过 65536 个范围。")
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

    /// 业务作用：流式注释类别含文档词及其异常类别，词内样式变化不能制造另一层注释折叠。
    /// 参数说明:
    /// - style: 当前完整原字节的原生类别。
    /// 返回：属于同一流式注释族时为真。
    private static func streamComment(_ style: UInt8) -> Bool {
        style == 1 || style == 3 || style == 17 || style == 18
    }

    /// 业务作用：折叠逐次读取相邻完整物理行，不为远端语法展开整个正文或跳过来源证据。
    /// 参数说明:
    /// - line: 当前固定正文中的逻辑行。
    /// - tree: 本轮固定正文树。
    /// - scanner: 共用语言与来源身份的扫描器。
    /// - state: 前一完整物理范围后的状态。
    /// - budget: 全部读取和折叠共用的预算。
    /// 返回：有界原字节及类别；行数之外为空，证据不足时拒绝完整折叠。
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
            throw NateError.message("Objective-C 折叠涉及超过 1 MiB 的物理行。")
        }
        let source = tree.text(in: range)
        let tokens = scanner.highlight(source, base: range.lower, state: &state)
        guard state.diagnostic == nil else {
            // 未确认的指令、字面或注释边界不能授予隐藏正文的资格。
            throw NateError.message(state.diagnostic ?? "Objective-C 折叠缺少完整词法证据。")
        }
        var classes = Array(repeating: UInt8(0), count: range.count)
        for token in tokens {
            guard let value = UInt8(token.lexicalStyle.dropFirst(5)) else {
                throw NateError.message("Objective-C 折叠缺少明确样式身份。")
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
