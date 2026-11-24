import NateCore

enum RubyFolding {
    /// 业务作用：折叠真实 Ruby 关键字块、独立操作符分组及已完成的专用多行字面。
    /// 参数说明:
    /// - snapshot: 与原始坐标一致的完整正文。
    /// - brackets: 同一正文经词法确认的原生操作符配对。
    /// - deadline: 折叠解析及所属请求共同拥有的截止。
    /// 返回：完整多行块及原字节端点，取消或资源超过时拒绝整份结果。
    static func regions(
        snapshot: DocumentSnapshot,
        brackets: [StructuralBracketPair] = [],
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        /// 业务作用：词元、原始行和折叠结果共享同一个任务截止。
        /// 参数说明: 无。
        /// 返回：仍可继续时通过，失去资格时终止所有解析结果。
        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("Ruby 折叠解析超过共同截止。")
            }
        }
        try check()
        let text = snapshot.text
        // 先取得全文处理资格，再读取有限物理段落，保证折叠不会只发布前半篇。
        guard text.byteCount <= 64 * 1_048_576, text.lineCount <= 1_048_576 else {
            throw NateError.message("Ruby 折叠解析超过 64 MiB 或 1048576 行。")
        }
        var lexer = RubyIndentationLexer()
        var structure = RubyIndentationState()
        var literal = RubyLiteralFolds()
        var regions: [FoldRegion] = []
        for line in 0..<text.lineCount {
            try check()
            let complete = text.lineRange(line)
            guard complete.count <= 1_048_576 else {
                throw NateError.message("Ruby 折叠解析单行超过 1 MiB。")
            }
            let body = text.lineRange(line, includeEnding: false)
            let row = try lexer.row(text.bytes(in: body), check: check)
            for closed in try literal.consume(row, line: line, body: body, check: check) {
                try append(closed, to: &regions)
            }
            if row.entirelyOpaque {
                continue
            }
            structure.beginLine(line, base: body.lower)
            for token in row.tokens {
                try check()
                try structure.consume(token, prefix: "")
                guard let closed = structure.closedBlock else {
                    continue
                }
                try append(closed, to: &regions)
            }
            structure.finishLine(opaque: row.holdsLiteral)
        }
        let closingOperators: [UInt8: UInt8] = [40: 41, 91: 93, 123: 125]
        for pair in brackets {
            try check()
            guard let close = closingOperators[pair.opener],
                text.byte(at: pair.range.lower) == pair.opener, text.byte(at: pair.range.upper - 1) == close
            else {
                continue
            }
            let start = text.lineNumber(at: pair.range.lower)
            let end = text.lineNumber(at: pair.range.upper - 1)
            if start < end {
                try append(
                    FoldRegion(range: pair.range, startLine: start, endLine: end, level: 0),
                    to: &regions
                )
            }
        }
        try check()
        return regions
    }

    /// 业务作用：所有折叠类别共用同一发布限额，任一类别过量都保留完整原文可见。
    /// 参数说明:
    /// - region: 当前实际闭合的多行候选。
    /// - regions: 本次尚未发布的完整折叠结果。
    /// 返回：有额度时加入当前结果，否则终止整份分析。
    private static func append(_ region: FoldRegion, to regions: inout [FoldRegion]) throws {
        guard regions.count < 65_536 else {
            throw NateError.message("Ruby 折叠解析超过 65536 个多行结构。")
        }
        regions.append(region)
    }
}
