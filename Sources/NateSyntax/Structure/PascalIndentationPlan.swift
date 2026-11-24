import Foundation
import NateCore

enum PascalIndentationPlan {
    /// 业务作用：沿同一份 Pascal 原生词法与结构状态准备整批换行，输入点之后的关键词不能提前改变该点的结构。
    /// 参数说明:
    /// - snapshot: 全部输入目标所属的固定正文与修订。
    /// - language: Pascal 的完整原生词表与样式。
    /// - ranges: 本次输入已经确认的全部实际替换范围。
    /// - deadline: 词法、缩进、事务和最终提交的共同截止。
    /// - permit: 当前输入仍有资格继续准备的检查。
    /// 返回：所有输入目标的完整动作；资格、原生词法或容量不足时整批抛错。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：让全部词法传播和目标处理服从同一输入资格。
        /// 参数说明: 无。
        /// 返回：仍可继续时通过，取消和时间超限时终止本次准备。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Pascal 语言缩进已取消或超过共同截止。")
            }
        }
        let source = snapshot.text
        var targets: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            targets[source.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = targets.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Pascal 语言缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var structure = PascalIndentationState()
        var remaining = 64 * 1024 * 1024
        var output: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let row = source.lineRange(line)
            // 在复制整行前验证范围预算，前面的光标不能在后面的目标超限时取得部分写入资格。
            guard row.count <= 1_048_576, row.count <= remaining else {
                throw NateError.message("Pascal 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remaining -= row.count
            let raw = source.text(in: row)
            let startsInDirective = [5, 6].contains(lexical.pascal.mode)
            let tokens = scanner.highlight(raw, base: row.lower, state: &lexical)
            // 缺少原生词法状态时，不允许用关键词外观推断字面或注释中的缩进。
            if let reason = lexical.diagnostic {
                throw NateError.message(reason)
            }
            let content = source.lineRange(line, includeEnding: false)
            let input = try PascalIndentationLine(
                raw: Array(raw.utf8.prefix(content.count)),
                base: row.lower,
                tokens: tokens,
                startsInDirective: startsInDirective,
                endsOpaque: [2, 3, 4, 5, 6, 10, 11, 15].contains(lexical.pascal.mode),
                check: check
            )
            try input.actions(
                for: targets[line] ?? [],
                structure: &structure,
                output: &output,
                check: check
            )
        }
        // 全部目标与前置结构已确认后才交出动作，取消时原文和选择仍由原事务持有。
        try check()
        return output
    }
}
