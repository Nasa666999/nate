import Foundation
import NateCore

extension SQLFolding {
    /// 业务作用：SQL 折叠按原生字节顺序推进语句、括号和注释状态，只发布完整有子行的范围。
    /// 参数说明:
    /// - snapshot: 本轮固定的完整正文。
    /// - language: 当前完整 SQL 名称与样式资源。
    /// - deadline: 所属操作共同截止。
    /// 返回：最多 65536 个完整范围；来源、层级或预算不足时整份拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let rows = try rows(snapshot: snapshot, language: language, deadline: deadline, budget: &budget)
        var state = SQLFoldState(), levels: [SQLFoldLevel] = []
        var previous: UInt8 = 0
        for (rowIndex, row) in rows.enumerated() {
            let bytes = snapshot.text.bytes(in: row.range)
            var ended = false
            for index in bytes.indices {
                try budget.consume()
                let byte = bytes[index]
                let nextByte = index + 1 < bytes.count ? bytes[index + 1] : 0
                let style = row.classes[index]
                let nextStyle =
                    index + 1 < row.classes.count
                    ? row.classes[index + 1]
                    : (rowIndex + 1 < rows.count ? rows[rowIndex + 1].classes.first ?? 0 : 0)
                let atEOL = byte == 10 || byte == 13 && nextByte != 10
                let semicolon = byte == 59 && !comment(style)
                if atEOL || semicolon {
                    state.boundary(semicolon: semicolon)
                }
                if byte == 58, nextByte == 61, !comment(style) {
                    state.flags |= SQLFoldState.select
                }
                if stream(style) {
                    if !stream(previous) {
                        state.next += 1
                    }
                    else if !stream(nextStyle), !atEOL {
                        state.next -= 1
                    }
                }
                if style == 2, byte == 45, nextByte == 45 {
                    let second = index + 2 < bytes.count ? bytes[index + 2] : 0
                    let third = index + 3 < bytes.count ? bytes[index + 3] : 0
                    if second == 123 || third == 123 {
                        state.next += 1
                    }
                    else if second == 125 || third == 125 {
                        state.next -= 1
                    }
                }
                if atEOL, row.commentLine {
                    let before = rowIndex > 0 && rows[rowIndex - 1].commentLine
                    let after = rowIndex + 1 < rows.count && rows[rowIndex + 1].commentLine
                    if !before, after {
                        state.next += 1
                    }
                    else if before, !after {
                        state.next -= 1
                    }
                }
                if style == 10 {
                    if byte == 40 {
                        if state.current > state.next {
                            state.current -= 1
                        }
                        state.next += 1
                    }
                    else if byte == 41 {
                        state.next -= 1
                    }
                    else if byte == 59 {
                        state.flags &= ~SQLFoldState.ignoreWhen
                    }
                }
                if style == 5, previous != 5 {
                    var word: [UInt8] = []
                    for distance in 0..<10 {
                        try budget.consume()
                        guard let candidate = snapshot.text.byte(at: row.range.lower + index + distance),
                            SQLScanner.wordPart(candidate) || candidate == 46
                        else {
                            break
                        }
                        word.append(candidate >= 65 && candidate <= 90 ? candidate + 32 : candidate)
                    }
                    if word.count <= 9 {
                        state.keyword(String(decoding: word, as: UTF8.self))
                    }
                }
                previous = style
                if atEOL {
                    ended = true
                }
            }
            // 原生 SQL 只在真实行尾发布层级；未终止末行保持默认层级，不提前隐藏末尾正文。
            guard (0...4095).contains(state.current), (0...4095).contains(state.next) else {
                throw NateError.message("SQL 折叠超过完整层级范围，正文保持可见。")
            }
            levels.append(
                SQLFoldLevel(
                    start: row.startLine,
                    end: row.endLine,
                    level: ended ? state.current : 1024,
                    header: ended && state.current < state.next
                )
            )
            if ended {
                state.current = state.next
                state.statementFound = false
            }
        }
        return try publish(levels, snapshot: snapshot, budget: &budget)
    }

    /// 业务作用：流注释与文档命令共享原生折叠边界，行注释另由成组规则处理。
    /// 参数说明:
    /// - style: 当前完整原生类别。
    /// 返回：流注释或流文档命令时为真。
    static func stream(_ style: UInt8) -> Bool {
        [1, 3, 17, 18].contains(style)
    }

    /// 业务作用：注释内分号和赋值标记不能解除 SQL 语句折叠状态。
    /// 参数说明:
    /// - style: 当前完整原生类别。
    /// 返回：普通、文档或单行注释时为真。
    static func comment(_ style: UInt8) -> Bool {
        [1, 2, 3, 15, 17, 18].contains(style)
    }
}
