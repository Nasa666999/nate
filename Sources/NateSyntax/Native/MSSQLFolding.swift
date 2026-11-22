import Foundation
import NateCore

enum MSSQLFolding {
    private struct Row {
        let start: Int
        let end: Int
        let level: Int
        let header: Bool
    }

    /// 业务作用：T-SQL 只由实际语句类别和完整块注释形成折叠，引用名称和字面中的关键字不隐藏正文。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前完整 T-SQL 名称与样式资源。
    /// - deadline: 词法和折叠共享的截止。
    /// 返回：最多 65536 个有子行的完整范围；来源、层级或预算不足时整份拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("T-SQL 折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState(), rows: [Row] = []
        var level = 1024, indentation = 0, position = 0
        while let byte = tree.byte(at: position), byte == 32 || byte == 9 {
            try budget.consume()
            indentation = byte == 32 ? indentation + 1 : (indentation / 8 + 1) * 8
            // 首行缩进参与原生起始层级；无法完整表示时不按截断位数隐藏正文。
            guard indentation <= 3071 else {
                throw NateError.message("T-SQL 首行折叠缩进超过完整层级范围。")
            }
            position += 1
        }
        level += indentation
        var line = 0, inComment = false
        while line < tree.lineCount {
            try budget.check()
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            let source = tree.text(in: range)
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 未确认的引号或后继证据不能让其中的名称取得折叠资格。
                throw NateError.message(state.diagnostic ?? "T-SQL 折叠缺少完整词法证据。")
            }
            let bytes = Array(source.utf8)
            var classes = Array(repeating: UInt8(0), count: bytes.count)
            for token in tokens {
                guard let style = UInt8(token.lexicalStyle.dropFirst(6)) else {
                    throw NateError.message("T-SQL 折叠缺少原生类别身份。")
                }
                for offset in token.range.lower..<token.range.upper {
                    try budget.consume()
                    classes[offset - range.lower] = style
                }
            }
            var next = level, visible = false, ended = false
            for index in bytes.indices {
                try budget.consume()
                let byte = bytes[index]
                let comment = classes[index] == 1
                if comment != inComment {
                    next += comment ? 1 : -1
                    inComment = comment
                }
                if classes[index] == 9, [66, 67, 69, 98, 99, 101].contains(byte) {
                    var word: [UInt8] = []
                    for distance in 0..<5 {
                        try budget.consume()
                        guard let candidate = tree.byte(at: range.lower + index + distance),
                            MSSQLScanner.wordPart(candidate)
                        else {
                            break
                        }
                        word.append(candidate >= 65 && candidate <= 90 ? candidate + 32 : candidate)
                    }
                    if word == Array("begin".utf8) || word == Array("case".utf8) {
                        next += 1
                    }
                    else if word == Array("end".utf8) {
                        next -= 1
                    }
                }
                if ![9, 10, 11, 12, 13, 32].contains(byte) {
                    visible = true
                }
                if byte == 10 || byte == 13 && tree.byte(at: range.lower + index + 1) != 10 {
                    ended = true
                }
            }
            // 截断层级会改变父子边界，无法完整表示时不能按截断值隐藏正文。
            guard (0...4095).contains(next) else {
                throw NateError.message("T-SQL 折叠层级超过 0–4095，正文保持可见。")
            }
            let end = range.isEmpty ? line : tree.lineNumber(at: range.upper - 1)
            rows.append(
                Row(
                    start: line,
                    end: end,
                    level: level,
                    header: ended && visible && next > level
                )
            )
            if ended {
                level = next
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
            guard end > start else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("T-SQL 折叠超过 65536 个完整范围。")
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
