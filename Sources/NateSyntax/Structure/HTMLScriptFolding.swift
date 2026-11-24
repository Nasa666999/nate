import Foundation
import NateCore

enum HTMLScriptFolding {
    /// 业务作用：在真实 HTML 标签已经界定的内嵌脚本原文中确认花括号、模板表达式及块注释。
    /// 参数说明:
    /// - range: 同一文档内开始标签之后到实际结束标签之前的完整原字节。
    /// - snapshot: 当前折叠源文档和修订。
    /// - rules: 同一语言注册表供应的完整 JavaScript 词法规则。
    /// - deadline: 标记和脚本共同拥有的截止。
    /// - check: 当前折叠计算的继续资格。
    /// - record: 登记已闭合的原始物理行范围。
    /// 返回：只登记本标签内已闭合的结构，超量或缺少完整词法时停止整份折叠。
    static func collect(
        range: ByteRange,
        snapshot: DocumentSnapshot,
        rules: ScriptRules,
        deadline: ContinuousClock.Instant,
        check: () throws -> Void,
        record: (Int, Int) throws -> Void
    ) throws {
        guard !range.isEmpty else {
            return
        }
        try check()
        let original = snapshot.text
        let firstLine = original.lineNumber(at: range.lower)
        // 用持久树共享脚本正文，只裁去标签和外部范围，使引号和句法不能跨越实际 HTML 边界。
        let tailRemoved = try original.replacing(ByteRange(range.upper, original.byteCount), with: "")
        let tree = try tailRemoved.replacing(ByteRange(0, range.lower), with: "")
        let source = DocumentSnapshot(id: snapshot.id, revision: snapshot.revision, text: tree)
        var lexical = SyntaxState()
        var braces: [Int] = []
        var commentStart: Int?
        for line in 0..<tree.lineCount {
            try check()
            let row = tree.lineRange(line)
            guard !row.isEmpty else {
                break
            }
            let body = tree.text(in: row)
            let tokens = ScriptLexing.highlight(
                body,
                base: row.lower,
                language: "javascript.js",
                snapshot: source,
                rules: rules,
                deadline: deadline,
                state: &lexical
            )
            if let reason = lexical.diagnostic {
                // 残缺脚本证据不得用来发布此前只完成一部分的折叠。
                throw NateError.message(reason)
            }
            let bytes = Array(body.utf8)
            var cursor = 0
            var token = 0
            var nextCheck = 0
            let originalLine = firstLine + line
            while cursor < bytes.count {
                if cursor >= nextCheck {
                    try check()
                    nextCheck = cursor + 256
                }
                let byte = bytes[cursor]
                let following = cursor + 1 < bytes.count ? bytes[cursor + 1] : nil
                if let start = commentStart {
                    if byte == 42, following == 47 {
                        commentStart = nil
                        try record(start, originalLine)
                        cursor += 2
                        continue
                    }
                }
                else {
                    let position = row.lower + cursor
                    while token < tokens.count, tokens[token].range.upper <= position {
                        token += 1
                    }
                    if token < tokens.count, tokens[token].range.lower <= position {
                        let style = tokens[token].lexicalStyle
                        if byte == 47, following == 42, style == "script:1" || style == "script:3" {
                            commentStart = originalLine
                            cursor += 2
                            continue
                        }
                        if style == "script:10", byte == 123 || byte == 125 {
                            if byte == 123 {
                                // 在完整脚本栈的容量内才允许积累范围，外层缺失时保留现有可见状态。
                                guard braces.count < 4096 else {
                                    throw NateError.message("HTML 内嵌脚本折叠超过 4096 层花括号。")
                                }
                                braces.append(originalLine)
                            }
                            else if let start = braces.popLast() {
                                try record(start, originalLine)
                            }
                        }
                    }
                }
                cursor += 1
            }
        }
        try check()
    }
}
