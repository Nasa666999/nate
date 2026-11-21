import Foundation
import NateCore

enum IHexFolding {
    /// 业务作用：Intel HEX 的扩展地址记录建立折叠范围，后续数据记录与普通行沿用该地址段层级。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 当前固定的 Intel HEX 语言资源。
    /// - deadline: 本次地址段转换的共同截止。
    /// 返回：至多 65536 个含从属行的范围；记录、容量、来源或时间证据不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("Intel HEX 折叠超过正文或行数预算。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 67_108_864)
        var levels = Array(repeating: 1024, count: tree.lineCount)
        var previous = 1024
        for line in 0..<tree.lineCount {
            try budget.check()
            let range = tree.lineRange(line)
            if range.isEmpty {
                break
            }
            guard range.count <= 1_048_576 else {
                throw NateError.message("Intel HEX 折叠涉及超过 1 MiB 的物理行。")
            }
            let tokens = scanner.highlight(tree.text(in: range), base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 未完成记录解析时不能根据外观推测地址段并隐藏其余固件记录。
                throw NateError.message(state.diagnostic ?? "Intel HEX 折叠缺少完整记录证据。")
            }
            var next = 1024
            for token in tokens {
                try budget.consume()
                if token.lexicalStyle == "ihex:11" {
                    next = 1024 | 8192
                }
                else if token.lexicalStyle == "ihex:7"
                    || token.lexicalStyle == "ihex:0" && token.range.lower == range.lower
                {
                    next = previous & 8192 != 0 ? 1025 : previous
                }
            }
            levels[line] = next
            previous = next
        }
        var output: [FoldRegion] = []
        var pending: Int?
        /// 业务作用：只有地址段确有从属行时才保留折叠，范围始终覆盖完整原始行。
        /// 参数说明:
        /// - first: 地址段标题所在真实行。
        /// - last: 最后一个从属真实行。
        /// 返回：合法非空范围进入有界临时结果，数量不足时整体拒绝。
        func append(_ first: Int, _ last: Int) throws {
            guard last > first else {
                return
            }
            guard output.count < 65_536 else {
                throw NateError.message("Intel HEX 折叠超过 65536 个范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(first).lower, tree.lineRange(last).upper),
                    startLine: first,
                    endLine: last,
                    level: 0
                )
            )
        }
        for line in levels.indices {
            try budget.consume()
            if levels[line] & 4095 <= 1024 {
                if let first = pending {
                    try append(first, line - 1)
                }
                pending = levels[line] & 8192 != 0 ? line : nil
            }
        }
        if let first = pending {
            try append(first, levels.count - 1)
        }
        try budget.check()
        return output
    }
}
