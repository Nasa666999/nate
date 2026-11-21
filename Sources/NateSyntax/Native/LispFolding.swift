import Foundation
import NateCore

enum LispFolding {
    /// 业务作用：Lisp 与 Scheme 只按操作符身份的三种括号计算行层级，字面内容中的括号不隐藏正文。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 当前固定语言及词表。
    /// - deadline: 本次转换的共同截止。
    /// 返回：最多 65536 个有从属行的范围；词法或预算不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("Lisp 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var levels = Array(repeating: 1024, count: tree.lineCount)
        var previous = 1024
        var current = 1024
        for line in 0..<tree.lineCount {
            try budget.consume()
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("Lisp 折叠涉及超过 1 MiB 的物理行。")
            }
            let text = tree.text(in: range)
            let tokens = scanner.highlight(text, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 不完整的读取宏身份不能授权隐藏后续行，失败保留全部正文。
                throw NateError.message(state.diagnostic ?? "Lisp 折叠缺少完整词法证据。")
            }
            var tokenIndex = 0
            var visible = 0
            for (offset, byte) in text.utf8.enumerated() {
                try budget.consume()
                let position = range.lower + offset
                while tokenIndex < tokens.count && tokens[tokenIndex].range.upper <= position {
                    tokenIndex += 1
                }
                if tokenIndex < tokens.count, tokens[tokenIndex].range.lower <= position,
                    tokens[tokenIndex].lexicalStyle == language.id + ":10"
                {
                    if [40, 91, 123].contains(byte) {
                        current += 1
                    }
                    else if [41, 93, 125].contains(byte) {
                        current -= 1
                    }
                }
                if byte == 10 || byte == 13 && tree.byte(at: position + 1) != 10 {
                    levels[line] = previous | (visible > 0 && current > previous ? 8192 : 0)
                    previous = current
                    if line + 1 < levels.count {
                        levels[line + 1] = previous
                    }
                }
                if byte != 32 && !(9...13).contains(byte) {
                    visible += 1
                }
            }
        }
        var ends = Array(repeating: levels.count - 1, count: levels.count)
        var stack: [Int] = []
        for line in levels.indices {
            try budget.consume()
            while let parent = stack.last, (levels[line] & 4095) <= (levels[parent] & 4095) {
                ends[parent] = line - 1
                stack.removeLast()
            }
            if levels[line] & 8192 != 0 {
                stack.append(line)
            }
        }
        var output: [FoldRegion] = []
        for line in levels.indices where levels[line] & 8192 != 0 && ends[line] > line {
            try budget.consume()
            guard output.count < 65_536 else {
                throw NateError.message("Lisp 折叠超过 65536 个范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(line).lower, tree.lineRange(ends[line]).upper),
                    startLine: line,
                    endLine: ends[line],
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
