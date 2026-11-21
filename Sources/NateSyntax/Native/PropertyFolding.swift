import Foundation
import NateCore

enum PropertyFolding {
    /// 业务作用：按配置节的真实行边界生成折叠，键值中的括号不制造嵌套代码块。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 已固定的 INI 或 Properties 定义。
    /// - deadline: 当前折叠转换的共同截止。
    /// 返回：至多 65536 个完整节范围；行、容量、取消或时间不足时保留全部正文可见。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.lineCount <= 1_048_576, tree.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("配置节折叠超过行数或正文预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 67_108_864)
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var levels: [Int] = []
        var previous = 1024
        for line in 0..<tree.lineCount {
            try budget.check()
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("配置节折叠涉及超过 1 MiB 的物理行。")
            }
            let source = tree.text(in: range)
            let tokens = scanner.highlight(source, base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 缺少完整词法证据时不能把任意方括号外观当成节标题并隐藏正文。
                throw NateError.message(state.diagnostic ?? "配置节折叠缺少完整词法状态。")
            }
            if source.utf8.last == 13 || source.utf8.last == 10 {
                var level = previous & 4095
                if tokens.contains(where: {
                    $0.lexicalStyle == "props:2"
                }) {
                    level = 1024 | 8192
                    // 连续节标题之间没有子行，前一个标题不能保留空的展开控制。
                    if previous & 8192 != 0, !levels.isEmpty {
                        levels[levels.count - 1] = 1024
                    }
                }
                else if previous & 8192 != 0 {
                    level += 1
                }
                var white = true
                for byte in source.utf8 {
                    try budget.consume()
                    if !PropertyLexing.space(byte) {
                        white = false
                    }
                }
                if white {
                    level |= 4096
                }
                levels.append(level)
                previous = level
            }
            else {
                // 没有真实结束符的末行继承前节深度，不能凭尚未结束的标题提前建立新折叠。
                levels.append((previous & 4095) + (previous & 8192 != 0 ? 1 : 0))
            }
        }
        var output: [FoldRegion] = []
        for line in levels.indices where levels[line] & 8192 != 0 {
            try budget.consume()
            var end = line
            while end + 1 < levels.count {
                try budget.consume()
                let next = levels[end + 1]
                guard next & 4096 != 0 || next & 4095 > 1024 else {
                    break
                }
                end += 1
            }
            guard end > line else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("配置节折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(line).lower, tree.lineRange(end).upper),
                    startLine: line,
                    endLine: end,
                    level: 1
                )
            )
        }
        try budget.check()
        return output
    }
}
