import Foundation
import NateCore

extension AutoItLexing {
    /// 业务作用：完整物理行类别只投影当前显示片段，完整属性与连续边界共同确认后推进缓存。
    /// 参数说明:
    /// - requested: 当前明确显示范围。
    /// - rules: 本轮固定完整样式资源。
    /// - cache: 调用流程独立持有的稳定段缓存。
    /// - budget: 当前分类与显示共享的预算。
    /// 返回：最多 65536 个非空完整词元；范围或样式不足时拒绝整份投影。
    static func project(
        _ requested: ByteRange,
        rules: AutoItRules,
        cache: inout AutoItLexicalCache,
        budget: inout ANSILexingBudget
    ) throws -> [SyntaxToken] {
        guard let range = cache.range, requested.lower >= range.lower, requested.upper <= range.upper else {
            throw NateError.message("AutoIt 显示范围不属于已确认的完整分类。")
        }
        let tokens = cache.tokens
        var lower = 0, upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].range.upper <= requested.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        var output: [SyntaxToken] = []
        for token in tokens.dropFirst(lower) {
            try budget.consume()
            if token.range.lower >= requested.upper {
                break
            }
            let start = max(token.range.lower, requested.lower)
            let end = min(token.range.upper, requested.upper)
            if start >= end {
                continue
            }
            guard output.count < 65_536, let attributes = rules.styles[String(token.style)] else {
                throw NateError.message("AutoIt 投影超过容量或缺少完整样式。")
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(start, end),
                    kind: token.kind,
                    foreground: attributes.foreground,
                    background: attributes.background,
                    fontStyle: attributes.fontStyle,
                    lexicalStyle: rules.languageID + ":" + String(token.style)
                )
            )
        }
        if requested.upper == range.upper {
            cache.range = nil
            cache.tokens = []
        }
        cache.nextOffset = requested.upper
        return output
    }
}
