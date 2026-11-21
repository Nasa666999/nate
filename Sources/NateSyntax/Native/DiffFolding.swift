import Foundation
import NateCore

enum DiffFolding {
    /// 业务作用：差异文件按命令、文件头和补丁位置形成层级，正文中的括号不参与补丁折叠。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 已固定的 diff 语言资源。
    /// - deadline: 本轮折叠转换的共同截止。
    /// 返回：至多 65536 个有子行的完整层级；来源、行数、容量、取消或时间不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("差异折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 67_108_864)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var levels = Array(repeating: 1024, count: tree.lineCount)
        var previous = 1024
        for line in 0..<tree.lineCount {
            try budget.check()
            let range = tree.lineRange(line)
            if range.isEmpty && line > 0 {
                break
            }
            guard range.count <= 1_048_576 else {
                throw NateError.message("差异折叠涉及超过 1 MiB 的物理行。")
            }
            let source = tree.text(in: range)
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 缺少完整行类别时不能凭行首标点隐藏后续补丁正文。
                throw NateError.message(state.diagnostic ?? "差异折叠缺少完整词法状态。")
            }
            let style = tokens.first?.lexicalStyle ?? "diff:0"
            let level: Int
            if style == "diff:2" {
                level = 1024 | 8192
            }
            else if style == "diff:3" {
                level = 1025 | 8192
            }
            else if style == "diff:4", source.utf8.first != 45 {
                level = 1026 | 8192
            }
            else {
                level = previous & 8192 != 0 ? (previous & 4095) + 1 : previous
            }
            // 同级连续标题没有独立子行，只有后一个标题继续持有层级起点。
            if level & 8192 != 0, level == previous, line > 0 {
                levels[line - 1] = previous & ~8192
            }
            levels[line] = level
            previous = level
        }
        var output: [FoldRegion] = []
        for line in levels.indices where levels[line] & 8192 != 0 {
            try budget.consume()
            var end = line
            let parent = levels[line] & 4095
            while end + 1 < levels.count, levels[end + 1] & 4095 > parent {
                try budget.consume()
                end += 1
            }
            guard end > line else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("差异折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(line).lower, tree.lineRange(end).upper),
                    startLine: line,
                    endLine: end,
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
