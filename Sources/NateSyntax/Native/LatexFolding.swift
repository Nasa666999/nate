import Foundation
import NateCore

enum LatexFolding {
    /// 业务作用：只依据当前 LaTeX 控制词身份建立环境与章节层级，逐字和注释中的外观不产生结构。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 当前固定语言资源。
    /// - deadline: 本次完整转换的共同截止。
    /// 返回：有从属行的完整范围；来源、词法、容量或时间证据不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("LaTeX 折叠超过正文或行数预算。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        var levels: [Int] = []
        var begins = Array(repeating: 0, count: 8)
        var structure = 0
        let names = [
            "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph",
        ]
        for line in 0..<tree.lineCount {
            try budget.consume()
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("LaTeX 折叠涉及超过 1 MiB 的物理行。")
            }
            let text = tree.text(in: range)
            let tokens = scanner.highlight(text, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 不完整的数学或逐字状态不能授权隐藏后续正文。
                throw NateError.message(state.diagnostic ?? "LaTeX 折叠缺少完整词法证据。")
            }
            let bytes = Array(text.utf8)
            var cursor = 0
            var tokenIndex = 0
            var level: Int?
            var header = false
            while cursor < bytes.count && bytes[cursor] != 13 && bytes[cursor] != 10 {
                try budget.consume()
                while tokenIndex < tokens.count && tokens[tokenIndex].range.upper <= range.lower + cursor {
                    tokenIndex += 1
                }
                if bytes[cursor] == 92, tokenIndex < tokens.count,
                    tokens[tokenIndex].range.lower <= range.lower + cursor,
                    tokens[tokenIndex].lexicalStyle == "latex:1"
                {
                    var word: [UInt8] = []
                    while word.count < 15 && cursor + 1 < bytes.count {
                        try budget.consume()
                        let next = bytes[cursor + 1]
                        if !LatexLexing.letter(next) {
                            break
                        }
                        word.append(next)
                        cursor += 1
                    }
                    let name = String(decoding: word, as: UTF8.self)
                    if name == "begin" {
                        level = level ?? depth(begins, structure)
                        begins[structure] += 1
                        header = true
                    }
                    else if name == "end" {
                        while structure > 0 && begins[structure] == 0 {
                            structure -= 1
                        }
                        level = level ?? depth(begins, structure)
                        if begins[structure] > 0 {
                            begins[structure] -= 1
                        }
                    }
                    else if let index = names.firstIndex(of: name) {
                        structure = index
                        for deeper in (structure + 1)..<8 {
                            begins[structure] += begins[deeper]
                            begins[deeper] = 0
                        }
                        level = level ?? depth(begins, structure)
                        structure += 1
                        header = true
                    }
                }
                cursor += 1
            }
            levels.append((level ?? depth(begins, structure)) | (header ? 8192 : 0))
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
                throw NateError.message("LaTeX 折叠超过 65536 个范围。")
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

    /// 业务作用：章节深度与各层未关闭环境共同决定行层级，保留固定十二位折叠数值。
    /// 参数说明:
    /// - begins: 各章节层的未关闭环境计数。
    /// - structure: 当前章节层。
    /// 返回：当前结构的完整行级别数值。
    static func depth(_ begins: [Int], _ structure: Int) -> Int {
        (1024 + structure + begins[0...structure].reduce(0, +)) & 4095
    }
}
