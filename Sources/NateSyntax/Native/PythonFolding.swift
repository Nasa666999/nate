import Foundation
import NateCore

// Python 折叠级别适配自 Lexilla 的 LexPython，原作者与许可见随包 licenses/sources.json。
private struct PythonFoldLine {
    let indentation: Int
    let blank: Bool
    let comment: Bool
    let quoted: Bool
}

private struct PythonFoldPlan {
    let levels: [Int]
    let headers: Set<Int>
}

enum PythonFolding {
    /// 业务作用：按 Python 缩进、三引号和非紧凑空行归属建立完整折叠范围，字面内部缩进不制造代码块。
    /// 参数说明:
    /// - snapshot: 当前已提交正文快照。
    /// - language: 当前 Python 关键字资源。
    /// - deadline: 本次语言结构转换的截止时刻。
    /// 返回：最多 65536 个多行范围；词法、缩进、行数或时间预算不足时不发布部分范围。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let lines = try lineFacts(snapshot: snapshot, language: language, deadline: deadline)
        let plan = try foldPlan(lines, deadline: deadline)
        var output: [FoldRegion] = []
        var stack: [Int] = []
        /// 业务作用：折叠只覆盖完整逻辑行并以合法 UTF-8 边界锚定，空行不产生虚构字符。
        /// 参数说明:
        /// - start: 具有折叠标记的标题行。
        /// - end: 最后一个从属真实行。
        /// 返回：有效多行范围进入临时结果，单行标记不隐藏正文。
        func append(_ start: Int, _ end: Int) {
            guard end > start else {
                return
            }
            let header = snapshot.text.lineRange(start, includeEnding: false)
            var leading = 0
            for byte in snapshot.text.text(in: header).utf8 {
                guard byte == 32 || byte == 9 else {
                    break
                }
                leading += 1
            }
            let upper = snapshot.text.lineRange(end, includeEnding: false).upper
            output.append(
                FoldRegion(
                    range: ByteRange(header.lower + leading, upper),
                    startLine: start,
                    endLine: end,
                    level: 0
                )
            )
        }
        for line in lines.indices {
            if line & 255 == 0 {
                try check(deadline)
            }
            while let header = stack.last, plan.levels[header] >= plan.levels[line] {
                stack.removeLast()
                append(header, line - 1)
            }
            if plan.headers.contains(line) {
                stack.append(line)
            }
        }
        for header in stack.reversed() {
            append(header, lines.count - 1)
        }
        try check(deadline)
        return output
    }

    /// 业务作用：从固定正文传播 Python 词法状态，以真实行首样式识别三引号区域。
    /// 参数说明:
    /// - snapshot: 当前不可变正文。
    /// - language: 当前 Python 语言资源。
    /// - deadline: 本次结构分析截止时刻。
    /// 返回：有界行属性；超长行、过深缩进或词法状态失效时拒绝继续隐藏正文。
    private static func lineFacts(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [PythonFoldLine] {
        guard snapshot.text.lineCount <= 1_048_576 else {
            throw NateError.message("Python 折叠暂停：真实行数超过 1048576 行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var output: [PythonFoldLine] = []
        output.reserveCapacity(snapshot.text.lineCount)
        var lastStyle = 0
        for line in 0..<snapshot.text.lineCount {
            try check(deadline)
            let range = snapshot.text.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("Python 折叠暂停：单行超过 1 MB。")
            }
            let text = snapshot.text.text(in: range)
            var indentation = 0
            var first: UInt8?
            for byte in text.utf8 {
                if byte == 32 {
                    indentation += 1
                }
                else if byte == 9 {
                    indentation = (indentation / 8 + 1) * 8
                }
                else {
                    first = byte
                    break
                }
                // 数值层级与结构标记必须保持独立，过深缩进不能越界形成虚假的折叠标题。
                guard indentation <= 3070 else {
                    throw NateError.message("Python 折叠暂停：缩进超过 3070 列。")
                }
            }
            let tokens = scanner.highlight(text, base: range.lower, state: &state)
            if let diagnostic = state.diagnostic {
                throw NateError.message(diagnostic)
            }
            let style: Int
            if range.isEmpty && range.lower == snapshot.text.byteCount {
                style = lastStyle
            }
            else if let token = tokens.first, token.range.lower == range.lower {
                style = Int(token.lexicalStyle.dropFirst(7)) ?? 0
            }
            else {
                style = 0
            }
            output.append(
                PythonFoldLine(
                    indentation: indentation,
                    // 未终止的空白尾行仍按实际缩进参与层级，不能与已有终止符的空行合并。
                    blank: range.isEmpty || first == 10 || first == 13,
                    comment: first == 35,
                    quoted: [6, 7, 18, 19].contains(style)
                )
            )
            if let token = tokens.last, token.range.upper == range.upper {
                lastStyle = Int(token.lexicalStyle.dropFirst(7)) ?? 0
            }
            else {
                lastStyle = 0
            }
        }
        return output
    }

    /// 业务作用：结合相邻有效缩进与三引号状态归属空行、注释和标题，保持非紧凑折叠语义。
    /// 参数说明:
    /// - lines: 完整词法传播得到的行属性。
    /// - deadline: 本次层级转换的截止时刻。
    /// 返回：完整数值层级与标题集合，容量或时间不足时抛错而不发布半成品。
    private static func foldPlan(_ lines: [PythonFoldLine], deadline: ContinuousClock.Instant) throws
        -> PythonFoldPlan
    {
        var levels = [Int](repeating: 0, count: lines.count)
        var headers: Set<Int> = []
        var current = lines[0].indentation
        var quoteBase = current
        var previousQuote = false
        var line = 0
        let last = lines.count - 1
        while line <= last {
            try check(deadline)
            var next = line + 1
            var following = next <= last ? lines[next].indentation : current
            let quote = next <= last && lines[next].quoted
            if !quote || !previousQuote {
                quoteBase = current
            }
            if quote || (next <= last && lines[next].blank) {
                following = quoteBase
            }
            var level = current
            if quote && !previousQuote {
                headers.insert(line)
            }
            else if previousQuote {
                level += 1
            }
            var minimumComment = quoteBase
            while !quote && next < last && (lines[next].blank || lines[next].comment) {
                if next & 255 == 0 {
                    try check(deadline)
                }
                if lines[next].comment {
                    minimumComment = min(minimumComment, following)
                }
                next += 1
                following = lines[next].indentation
            }
            let afterComments = next < last ? following : minimumComment
            for skipped in (line + 1)..<min(next, lines.count) {
                if skipped & 255 == 0 {
                    try check(deadline)
                }
                levels[skipped] = afterComments
            }
            if !quote && !lines[line].blank && current < following {
                headers.insert(line)
            }
            guard headers.count <= 65_536 else {
                throw NateError.message("Python 折叠暂停：多行结构数量超过 65536 个。")
            }
            levels[line] = level
            current = following
            previousQuote = quote
            line = next
        }
        return PythonFoldPlan(
            levels: levels,
            headers: headers
        )
    }

    /// 业务作用：在物理行和有界层级整理边界响应取消，旧结构不能在资源失效后继续发布。
    /// 参数说明:
    /// - deadline: 当前完整分析截止时刻。
    /// 返回：仍有时间与执行资格时继续，否则抛错并丢弃临时结果。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("Python 折叠暂停：当前结构分析超过 5 秒。")
        }
    }
}
