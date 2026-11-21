import Foundation
import NateCore

enum RegistryFolding {
    /// 业务作用：Registry 的新增或删除键路径建立节范围，GUID 与字符串中的方括号不伪造节标题。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - language: 当前固定的 Registry 资源。
    /// - deadline: 本轮折叠转换的共同截止。
    /// 返回：至多 65536 个含子行的完整节范围；词法、来源、数量、取消或截止不足时整体拒绝。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("Registry 折叠超过正文或行数预算。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 67_108_864)
        var headers: [Int] = []
        for line in 0..<tree.lineCount {
            try budget.consume()
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("Registry 折叠涉及超过 1 MiB 的物理行。")
            }
            let tokens = scanner.highlight(tree.text(in: range), base: range.lower, state: &state)
            guard state.diagnostic == nil else {
                // 键路径身份不完整时不能根据方括号外观隐藏后续注册表正文。
                throw NateError.message(state.diagnostic ?? "Registry 折叠缺少完整词法证据。")
            }
            for token in tokens {
                try budget.consume()
                if token.lexicalStyle == "registry:6" || token.lexicalStyle == "registry:7" {
                    headers.append(line)
                    break
                }
            }
        }
        var output: [FoldRegion] = []
        for index in headers.indices {
            try budget.consume()
            let first = headers[index]
            let last = index + 1 < headers.count ? headers[index + 1] - 1 : tree.lineCount - 1
            guard last > first else {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("Registry 折叠超过 65536 个范围。")
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
        try budget.check()
        return output
    }
}
