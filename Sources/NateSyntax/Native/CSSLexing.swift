import Foundation
import NateCore

enum CSSLexing {
    /// 业务作用：CSS 在固定原文中先确认完整未决段，再按连续显示范围交付有限样式。
    /// 参数说明:
    /// - text: 当前显示片段的完整原文。
    /// - base: 片段在固定正文中的原字节起点。
    /// - snapshot: 本轮固定全文及有界后继来源。
    /// - rules: 完整 CSS 词表与样式。
    /// - deadline: 所属操作的共同截止。
    /// - state: 调用流程独立持有的连续状态。
    /// 返回：最多 65536 个完整词元；失败只设置诊断，不发布部分状态或修改正文。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: CSSRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 33_554_432)
            try budget.check()
            // 完整规则与连续位置共同授予缓存资格，缺少来源不能沿另一段的类别继续解释。
            guard let rules, text.utf8.count <= 1_048_576, base >= 0,
                base <= Int.max - text.utf8.count,
                state.cssCache.nextOffset == nil ? base == 0 : state.cssCache.nextOffset == base,
                state.css.resource == nil || state.css.resource == rules.identity
            else {
                throw NateError.message("CSS 高亮缺少完整规则或连续原字节。")
            }
            var unrelated = state
            unrelated.css = CSSLexicalState()
            unrelated.cssCache = CSSLexicalCache()
            // 字节零也不能继承其它语言的控制状态，语言切换必须显式重建。
            guard unrelated == SyntaxState() else {
                throw NateError.message("CSS 不能承接其它语言的词法状态。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                guard state.css.documentID == nil || state.css.documentID == snapshot.id,
                    state.css.revision == nil || state.css.revision == snapshot.revision,
                    state.css.sourceIdentity == nil
                        || state.css.sourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("CSS 范围与正文身份、修订或原字节不一致。")
                }
            }
            else if state.css.sourceIdentity != nil {
                throw NateError.message("CSS 不能失去固定正文来源。")
            }
            else if base > 0 {
                // 未决名称可以改变此前空白的颜色，无全文证据时不得续接已按 EOF 解释的段。
                guard state.css.physicalBoundary, !CSSScanner.pending(state.css.mode),
                    !(state.css.previousScalar == 13 && text.utf8.first == 10)
                else {
                    throw NateError.message("CSS 连续范围缺少完整物理边界或后继来源。")
                }
            }
            var local = state
            if local.cssCache.range == nil {
                let physical =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard physical.lower == requested.lower, physical.count <= 1_048_576 else {
                    throw NateError.message("CSS 缺少物理行首或单行超过 1 MiB。")
                }
                var upper = physical.upper
                if let snapshot {
                    upper += min(1_048_576, snapshot.text.byteCount - upper)
                    while !snapshot.text.isBoundary(upper) {
                        try budget.consume()
                        upper -= 1
                    }
                    if snapshot.text.byte(at: upper - 1) == 13, snapshot.text.byte(at: upper) == 10 {
                        upper -= 1
                    }
                }
                let initial = local.css
                var scanner = CSSScanner(
                    bytes: snapshot?.text.bytes(in: physical) ?? Array(text.utf8),
                    base: physical.lower,
                    wantedUpper: physical.upper,
                    snapshot: snapshot,
                    trueEOF: snapshot.map { physical.upper == $0.text.byteCount } ?? true,
                    limitUpper: upper,
                    rules: rules,
                    budget: budget,
                    state: initial
                )
                let chunk = try scanner.scan()
                budget = scanner.budget
                local.css = chunk.state
                local.css.documentID = snapshot?.id
                local.css.revision = snapshot?.revision
                local.css.sourceIdentity = snapshot?.text.sourceIdentity
                local.css.resource = rules.identity
                local.cssCache.range = chunk.range
                local.cssCache.tokens = chunk.tokens
                local.cssCache.initial = initial
            }
            let output = try project(requested, rules: rules, cache: &local.cssCache, budget: &budget)
            // 完整后继与投影全部确认后才发布，迟到取消不能保留部分跨行颜色。
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
