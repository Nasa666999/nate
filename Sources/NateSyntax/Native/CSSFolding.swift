import Foundation
import NateCore

enum CSSFolding {
    private struct Row {
        let start: Int
        let end: Int
        let level: Int
        let header: Bool
    }

    /// 业务作用：普通 CSS 只按原生操作符花括号和注释类别变化建立完整折叠。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前完整 CSS 词表与样式。
    /// - deadline: 词法和折叠共享的截止。
    /// 返回：最多 65536 个有子行的完整范围；来源、层级或预算不足时整份拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("CSS 折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState(), rows: [Row] = []
        var previous = 1024, level = 1024, inComment = false, line = 0
        while line < tree.lineCount {
            try budget.check()
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            let source = tree.text(in: range)
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            // 缺少完整 CSS 类别时不能将字符串或属性内容作为可隐藏的代码结构。
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "CSS 折叠缺少完整词法证据。")
            }
            let bytes = Array(source.utf8)
            var classes = Array(repeating: UInt8(0), count: bytes.count)
            for token in tokens {
                guard let style = UInt8(token.lexicalStyle.dropFirst(4)) else {
                    throw NateError.message("CSS 折叠缺少原生类别身份。")
                }
                for offset in token.range.lower..<token.range.upper {
                    try budget.consume()
                    classes[offset - range.lower] = style
                }
            }
            var visible = false, ended = false
            for index in bytes.indices {
                try budget.consume()
                let comment = classes[index] == 9
                if comment != inComment {
                    level += comment ? 1 : -1
                    inComment = comment
                }
                if classes[index] == 5 {
                    if bytes[index] == 123 {
                        level += 1
                    }
                    else if bytes[index] == 125 {
                        level -= 1
                    }
                }
                if bytes[index] == 10 || bytes[index] == 13 && tree.byte(at: range.lower + index + 1) != 10 {
                    ended = true
                }
                if ![9, 10, 11, 12, 13, 32].contains(bytes[index]) {
                    visible = true
                }
            }
            // 层级截断会改变父子边界，超出完整表示范围时保持正文可见。
            guard (0...4095).contains(level), (0...4095).contains(previous) else {
                throw NateError.message("CSS 折叠超过完整层级范围。")
            }
            let end = range.isEmpty ? line : tree.lineNumber(at: range.upper - 1)
            rows.append(
                Row(
                    start: line,
                    end: end,
                    level: previous,
                    header: ended && visible && level > previous
                )
            )
            if ended {
                previous = level
            }
            line = end + 1
        }
        var ends = Array(repeating: rows.count - 1, count: rows.count)
        var stack: [Int] = []
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
            let start = rows[index].start, end = rows[ends[index]].end
            if end <= start {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("CSS 折叠超过 65536 个完整范围。")
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
