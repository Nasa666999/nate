import Foundation
import NateCore

enum ScriptLexing {
    /// 业务作用：脚本按完整物理范围统一分类，Unicode 显示分段共享同源词元与行内错误身份。
    /// 参数说明:
    /// - text: 当前显示分段的完整原文。
    /// - base: 分段在固定正文中的原字节起点。
    /// - language: 明确的脚本模式。
    /// - snapshot: 固定正文和真实物理行来源。
    /// - rules: 有界且完整的脚本词表与样式。
    /// - deadline: 本次操作共同截止。
    /// - state: 调用流程独立持有的连续检查点。
    /// 返回：最多 65536 个完整词元；来源或预算不足时只记录诊断，不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        language: String,
        snapshot: DocumentSnapshot?,
        rules: ScriptRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 16_777_216)
            try budget.check()
            guard let rules, text.utf8.count <= 1_048_576, base >= 0,
                base <= Int.max - text.utf8.count,
                state.scriptCache.nextOffset == nil ? base == 0 : state.scriptCache.nextOffset == base,
                state.c.scriptResource == nil || state.c.scriptResource == rules.identity
            else {
                throw NateError.message("脚本高亮缺少完整规则或连续分段。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                // 缓存类别同样属于原正文根，显示投影不能绕过词法来源和修订门禁。
                guard state.c.documentID == nil || state.c.documentID == snapshot.id,
                    state.c.revision == nil || state.c.revision == snapshot.revision,
                    state.c.scriptSourceIdentity == nil
                        || state.c.scriptSourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("脚本显示范围与固定正文或缓存来源不一致。")
                }
            }
            else if state.c.scriptSourceIdentity != nil {
                throw NateError.message("脚本连续投影不能失去固定正文来源。")
            }
            var local = state
            if local.scriptCache.range == nil {
                let range =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard range.lower == requested.lower, range.count <= 1_048_576 else {
                    throw NateError.message("脚本高亮缺少物理行首或超过单行 1 MiB。")
                }
                let initial = local.c
                let source = snapshot?.text.text(in: range) ?? text
                let tokens = CLexing.highlight(
                    source,
                    base: range.lower,
                    language: language,
                    keywords: [],
                    secondaryKeywords: [],
                    globalClasses: [],
                    documentationKeywords: [],
                    snapshot: snapshot,
                    scriptRules: rules,
                    deadline: deadline,
                    state: &local
                )
                guard local.diagnostic == nil else {
                    throw NateError.message(local.diagnostic ?? "脚本物理范围缺少完整分类。")
                }
                local.scriptCache.range = range
                local.scriptCache.initial = initial
                local.scriptCache.tokens = try tokens.map {
                    try budget.consume()
                    guard let style = UInt8($0.lexicalStyle.dropFirst(7)) else {
                        throw NateError.message("脚本缓存缺少原生类别。")
                    }
                    return ScriptCachedToken(
                        range: $0.range,
                        kind: $0.kind.rawValue,
                        style: style
                    )
                }
            }
            guard let range = local.scriptCache.range, requested.lower >= range.lower,
                requested.upper <= range.upper
            else {
                throw NateError.message("脚本显示片段不属于完整物理分类。")
            }
            var output: [SyntaxToken] = []
            let cached = local.scriptCache.tokens
            var lowerIndex = 0, upperIndex = cached.count
            while lowerIndex < upperIndex {
                let middle = lowerIndex + (upperIndex - lowerIndex) / 2
                if cached[middle].range.upper <= requested.lower {
                    lowerIndex = middle + 1
                }
                else {
                    upperIndex = middle
                }
            }
            for token in cached.dropFirst(lowerIndex) {
                try budget.consume()
                if token.range.lower >= requested.upper {
                    break
                }
                let lower = max(requested.lower, token.range.lower)
                let upper = min(requested.upper, token.range.upper)
                guard upper > lower else {
                    continue
                }
                guard output.count < 65_536, let kind = SyntaxKind(rawValue: token.kind),
                    let attributes = rules.styles[String(token.style)]
                else {
                    throw NateError.message("脚本显示片段超过容量或缺少完整属性。")
                }
                output.append(
                    SyntaxToken(
                        range: ByteRange(lower, upper),
                        kind: kind,
                        foreground: attributes.foreground,
                        background: attributes.background,
                        fontStyle: attributes.fontStyle,
                        lexicalStyle: "script:" + String(token.style)
                    )
                )
            }
            if requested.upper == range.upper {
                local.scriptCache.range = nil
                local.scriptCache.tokens = []
                local.scriptCache.initial = nil
            }
            local.scriptCache.nextOffset = requested.upper
            // 完整物理分类及分段投影全部成功后才发布检查点，失败保留此前全部状态。
            try budget.check()
            state = local
            return output
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }
}
