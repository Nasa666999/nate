import Foundation
import NateCore

enum CMakeFolding {
    /// 业务作用：CMake 保留每个 LF 段首个原文单词的控制结构折叠，发布前确认同源词法与完整层级。
    /// 参数说明:
    /// - snapshot: 本轮固定完整正文。
    /// - language: 当前完整三组词表与十五种样式。
    /// - deadline: 词法与折叠共用的操作截止。
    /// 返回：最多 65536 个完整多行范围；来源、容量或截止不足时整份拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("CMake 折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState(), line = 0
        while line < tree.lineCount {
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            _ = scanner.highlight(tree.text(in: range), base: range.lower, state: &state)
            // 缺少同一完整来源时不能将部分原文发布为可隐藏范围。
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "CMake 折叠缺少完整词法来源。")
            }
            line = range.isEmpty ? line + 1 : tree.lineNumber(at: range.upper - 1) + 1
        }
        let raw = tree.bytes(in: ByteRange(0, tree.byteCount))
        var levels = Array(repeating: 1024, count: tree.lineCount)
        var current = 1024, next = 1024, target = 0, first = true
        var word: [UInt8] = [], length = 0
        for byte in raw {
            try budget.consume()
            if first {
                let letter = byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
                if letter {
                    length += 1
                    if word.count < 19 {
                        word.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
                    }
                }
                else if length > 0 {
                    if length <= 21 {
                        let name = String(decoding: word, as: UTF8.self)
                        if ["if", "while", "macro", "foreach", "function"].contains(name) {
                            next += 1
                        }
                        else if ["endif", "endwhile", "endmacro", "endforeach", "endfunction"].contains(name)
                        {
                            next -= 1
                        }
                    }
                    first = false
                }
            }
            guard next >= 0, next <= 4095 else {
                throw NateError.message("CMake 折叠超过完整层级范围。")
            }
            if byte == 10 {
                guard target < levels.count else {
                    throw NateError.invalidRange
                }
                levels[target] = current | (current < next ? 8192 : 0)
                target += 1
                current = next
                first = true
                word = []
                length = 0
            }
        }
        // 原生折叠只在 LF 和 EOF 发布；CR 独立物理行仍保留尚未赋值的基础层级。
        guard target < levels.count else {
            throw NateError.invalidRange
        }
        levels[target] = current | (current < next ? 8192 : 0)
        var ends = Array(repeating: levels.count - 1, count: levels.count), stack: [Int] = []
        for index in levels.indices {
            try budget.consume()
            while let parent = stack.last, levels[index] & 4095 <= levels[parent] & 4095 {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if levels[index] & 8192 != 0 {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in levels.indices where levels[index] & 8192 != 0 {
            try budget.consume()
            let end = ends[index]
            if end <= index {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("CMake 折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(index).lower, tree.lineRange(end).upper),
                    startLine: index,
                    endLine: end,
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
