import Foundation
import NateCore

struct SQLFoldRow {
    let range: ByteRange
    let startLine: Int
    let endLine: Int
    let classes: [UInt8]
    let commentLine: Bool
}

struct SQLFoldLevel {
    let start: Int
    let end: Int
    let level: Int
    let header: Bool
}

enum SQLFolding {
    /// 业务作用：所有 SQL 物理行先取得同源完整类别，成组行注释不依靠未确认的后继猜测。
    /// 参数说明:
    /// - snapshot: 当前固定的完整正文。
    /// - language: 本轮完整 SQL 语言资源。
    /// - deadline: 词法与折叠共享的截止。
    /// - budget: 原字节类别展开共享的步骤预算。
    /// 返回：最多 1048576 行和 64 MiB 的完整类别；任一行拒绝时不保留部分折叠。
    static func rows(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant,
        budget: inout ANSILexingBudget
    ) throws -> [SQLFoldRow] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("SQL 折叠超过行数或正文预算。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState(), result: [SQLFoldRow] = []
        var line = 0
        while line < tree.lineCount {
            try budget.check()
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            let source = tree.text(in: range)
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            // 未确认的注释、字面或原文边界不能参与折叠，整份结果必须保持正文可见。
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "SQL 折叠缺少完整词法证据。")
            }
            let bytes = Array(source.utf8)
            var classes = Array(repeating: UInt8(0), count: bytes.count)
            for token in tokens {
                guard let style = UInt8(token.lexicalStyle.dropFirst(4)) else {
                    throw NateError.message("SQL 折叠缺少原生类别身份。")
                }
                for offset in token.range.lower..<token.range.upper {
                    try budget.consume()
                    classes[offset - range.lower] = style
                }
            }
            var comment = false
            for index in 0..<max(0, bytes.count - 2) {
                try budget.consume()
                if classes[index] == 2, bytes[index] == 45, bytes[index + 1] == 45 {
                    comment = true
                    break
                }
                if bytes[index] != 9, bytes[index] != 32 {
                    break
                }
            }
            let end = range.isEmpty ? line : tree.lineNumber(at: range.upper - 1)
            result.append(
                SQLFoldRow(
                    range: range,
                    startLine: line,
                    endLine: end,
                    classes: classes,
                    commentLine: comment
                )
            )
            line = end + 1
        }
        return result
    }
}
