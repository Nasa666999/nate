import Foundation
import NateCore

enum AutoItIndentationPlan {
    /// 业务作用：全部 AutoIt 换行目标沿同一原生词法与结构来源准备，真实分支和闭合引用其原始空白前缀。
    /// 参数说明:
    /// - snapshot: 本次输入固定的完整原文。
    /// - language: 当前 AutoIt 原生词表及样式。
    /// - ranges: 同一来源内的全部真实替换范围。
    /// - deadline: 本次准备与最终提交的共同截止。
    /// - permit: 当前输入继续准备的资格。
    /// 返回：全部目标的不可变动作；词法、容量、来源或执行资格不足时整份抛错。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        var budget = AutoItIndentationBudget(deadline: deadline, permit: permit)
        try budget.check()
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try budget.consume()
            byLine[snapshot.text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("AutoIt 语言缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var structure = AutoItIndentationState()
        var output: [ByteRange: NewlineIndentationAction] = [:]
        var consumed = 0
        for line in 0...last {
            try budget.check()
            let row = snapshot.text.lineRange(line)
            // 完整行和前置容量先于原文副本确认，长行不能留下部分光标已经准备好的动作。
            guard row.count <= 1_048_576, row.count <= 67_108_864 - consumed else {
                throw NateError.message("AutoIt 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            consumed += row.count
            try budget.consume(row.count)
            let raw = snapshot.text.text(in: row)
            let tokens = scanner.highlight(raw, base: row.lower, state: &lexical)
            // 缺少原生词法传播时不能把未知字面区域重新解释为代码，也不能发布前面已经准备的目标。
            guard lexical.diagnostic == nil else {
                throw NateError.message(lexical.diagnostic ?? "AutoIt 语言缩进缺少完整词法状态。")
            }
            var code = Array(raw.utf8)
            let prefix = try indentation(code, budget: &budget)
            for token in tokens where token.isStructureOpaque {
                // 字面必须占据表达式位置，不能让字符串前的 Then 冒充多行块；注释不再贡献结构证据。
                let replacement: UInt8 = token.kind == .string ? 127 : 32
                for index in (token.range.lower - row.lower)..<(token.range.upper - row.lower) {
                    try budget.consume()
                    code[index] = replacement
                }
            }
            let targets = byLine[line] ?? []
            for target in targets {
                let offset = target.lower - row.lower
                try budget.consume(offset)
                var preview = structure
                output[target] = try preview.consume(
                    Array(code[..<offset]),
                    prefix: prefix,
                    budget: &budget
                )
            }
            _ = try structure.consume(code, prefix: prefix, budget: &budget)
        }
        // 全部行的原生词法与每个目标的结构资格同时成立后才发布，迟到取消不能保留前半份动作。
        try budget.check()
        return output
    }

    /// 业务作用：对齐只复用真实行首空白，不把任意正文或字符串片段作为可插入的缩进内容。
    /// 参数说明:
    /// - code: 当前物理行的原字节。
    /// - budget: 整批输入的共同额度。
    /// 返回：保留混合 Tab 和空格的完整前缀；取消或超限时抛错。
    private static func indentation(_ code: [UInt8], budget: inout AutoItIndentationBudget) throws -> String {
        var end = 0
        while end < code.count && (code[end] == 9 || code[end] == 32) {
            try budget.consume()
            end += 1
        }
        return String(decoding: code[..<end], as: UTF8.self)
    }
}
