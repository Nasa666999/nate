import NateCore

struct RubyLiteralFolds {
    private struct Opening {
        let line: Int
        let byte: Int
    }

    private struct WordList {
        let opening: Opening
        let style: RubyHighlightStyle
    }

    private var heredoc: Opening?
    private var pendingHeredocs = 0
    private var words: WordList?

    /// 业务作用：Ruby 的 heredoc 与百分号单词数组只沿已确认的字面边界折叠，字面内的括号和关键词不提供代码块。
    /// 参数说明:
    /// - row: 同一 Ruby 词法已读取的当前完整物理行。
    /// - line: 所属真实物理行号。
    /// - body: 物理正文的绝对 UTF-8 范围，排除行结束字节。
    /// - check: 词法推进及折叠结果的共同截止。
    /// 返回：在此行完整闭合的多行字面范围，尚未闭合时保留实际开端。
    mutating func consume(
        _ row: RubyIndentationLexer.Row,
        line: Int,
        body: ByteRange,
        check: () throws -> Void
    ) throws -> [FoldRegion] {
        var finished: [FoldRegion] = []
        if row.heredocEnd != nil, let heredoc {
            pendingHeredocs -= 1
            if pendingHeredocs == 0 {
                // 同物理行可声明多个正文，最后一个真实分隔符之前始终属于同一行的折叠范围。
                finished.append(region(from: heredoc, through: line, ending: body.upper))
                self.heredoc = nil
            }
        }
        for (index, token) in row.tokens.enumerated() {
            try check()
            if token.highlightStyle == .heredocDelimiter {
                if heredoc == nil {
                    heredoc = Opening(line: line, byte: body.lower + token.span.lower)
                }
                pendingHeredocs += 1
                continue
            }
            guard let style = token.highlightStyle, style == .wordList || style == .interpolatedWords else {
                continue
            }
            let continues = token.span.upper == body.count && row.endingStyle == style
            if index == 0, row.beginsInLiteral, let opening = words, opening.style == style {
                if !continues {
                    finished.append(
                        region(from: opening.opening, through: line, ending: body.lower + token.span.upper)
                    )
                    words = nil
                }
            }
            else if continues {
                words = WordList(
                    opening: Opening(line: line, byte: body.lower + token.span.lower),
                    style: style
                )
            }
        }
        return finished
    }

    /// 业务作用：以已经证明配对的原始端点形成折叠候选，层级由全文索引统一管理。
    /// 参数说明:
    /// - opening: 本字面的真实开端。
    /// - line: 独立的闭合物理行。
    /// - ending: 闭合标记之后的绝对原字节位置。
    /// 返回：可安全提交给原生折叠视图的多行候选。
    private func region(from opening: Opening, through line: Int, ending: Int) -> FoldRegion {
        FoldRegion(range: ByteRange(opening.byte, ending), startLine: opening.line, endLine: line, level: 0)
    }
}
