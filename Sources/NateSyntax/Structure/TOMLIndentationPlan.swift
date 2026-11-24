import Foundation
import NateCore

enum TOMLIndentationPlan {
    /// 业务作用：从同一固定 TOML 词法分类准备数组和内联表的结构换行，表头和字面不取得容器资格。
    /// 参数说明:
    /// - snapshot: 本次全部目标使用的完整正文。
    /// - language: 当前 TOML 的固定词表及原生样式。
    /// - ranges: 输入事务已经复验的全部真实目标。
    /// - deadline: 词法、缩进及最终提交的共同截止。
    /// - permit: 当前编辑动作继续准备的资格。
    /// 返回：所有目标的完整动作；来源、容量、取消或词法不足时整体失败。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：传播、真实括号和全部插入点共享一次输入的继续资格。
        /// 参数说明: 无。
        /// 返回：操作仍有效时通过，否则停止整批结构换行准备。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("TOML 语言缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var targetsByLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            targetsByLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = targetsByLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("TOML 语言缩进的前置传播超过一百万行。")
        }
        var remainingBytes = 64 * 1024 * 1024
        var remainingPrefixes = 1024 * 1024
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var containers: [TOMLIndentationLine.Container] = []
        var output: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let complete = text.lineRange(line)
            // 原行容量与词法可信度先于选区发布，拒绝一部分目标采用尚未确认的上下文。
            guard complete.count <= 1024 * 1024, complete.count <= remainingBytes else {
                throw NateError.message("TOML 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remainingBytes -= complete.count
            let row = text.lineRange(line, includeEnding: false)
            let source = text.text(in: complete)
            let tokens = scanner.highlight(source, base: complete.lower, state: &lexical)
            if let reason = lexical.diagnostic {
                throw NateError.message(reason)
            }
            let bytes = Array(source.utf8.prefix(row.count))
            var current = TOMLIndentationLine(bytes: bytes, base: row.lower, tokens: tokens)
            let targets = targetsByLine[line] ?? []
            let suffixes = try current.closingSuffixes(targets: targets, check: check)
            for target in targets.sorted(by: { $0.lower < $1.lower }) {
                try check()
                let offset = min(bytes.count, target.lower - row.lower)
                try current.scan(
                    through: offset,
                    containers: &containers,
                    remainingPrefixes: &remainingPrefixes,
                    check: check
                )
                output[target] = current.action(at: offset, next: suffixes[target], containers: containers)
            }
            try current.scan(
                through: bytes.count,
                containers: &containers,
                remainingPrefixes: &remainingPrefixes,
                check: check
            )
        }
        try check()
        return output
    }
}
