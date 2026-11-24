import NateCore

enum RubyFolding {
    /// 业务作用：只折叠 Ruby 真实代码的完整关键字块，使用与回车缩进相同的字面隔离和结束端判定。
    /// 参数说明:
    /// - snapshot: 与原始坐标一致的完整正文。
    /// - deadline: 折叠解析及所属请求共同拥有的截止。
    /// 返回：完整多行块及原字节端点，取消或资源超过时拒绝整份结果。
    static func regions(snapshot: DocumentSnapshot, deadline: ContinuousClock.Instant) throws -> [FoldRegion]
    {
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
        var regions: [FoldRegion] = []
        for line in 0..<text.lineCount {
            try check()
            let complete = text.lineRange(line)
            guard complete.count <= 1_048_576 else {
                throw NateError.message("Ruby 折叠解析单行超过 1 MiB。")
            }
            let body = text.lineRange(line, includeEnding: false)
            let row = try lexer.row(text.bytes(in: body), check: check)
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
                guard regions.count < 65_536 else {
                    throw NateError.message("Ruby 折叠解析超过 65536 个多行结构。")
                }
                regions.append(closed)
            }
            structure.finishLine(opaque: row.holdsLiteral)
        }
        try check()
        return regions
    }
}
