import Foundation
import NateCore

enum NncronLexing {
    /// 业务作用：nnCron 完整物理行先分类再投影，任务、字面及环境变量状态只沿同一原文连续传播。
    /// 参数说明:
    /// - text: 本次展示片段的原文。
    /// - base: 展示片段的原字节起点。
    /// - snapshot: 当前固定完整原文。
    /// - rules: 完整 nnCron 三组词表与样式。
    /// - deadline: 所属操作的共同截止。
    /// - state: 由当前调用流程独立持有的连续状态。
    /// 返回：完整片段的有限样式；失败只设置诊断，正文与历史不变。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: NncronRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 33_554_432)
            try budget.check()
            // 规则与连续字节共同授予状态资格，缺少来源时不得把另一行的任务或字面状态继续开放。
            guard let rules, text.utf8.count <= 1_048_576, base >= 0,
                base <= Int.max - text.utf8.count,
                state.nncrontabCache.nextOffset == nil ? base == 0 : state.nncrontabCache.nextOffset == base,
                state.nncrontab.resource == nil || state.nncrontab.resource == rules.identity
            else {
                throw NateError.message("nnCron 高亮缺少完整规则或连续原字节。")
            }
            var unrelated = state
            unrelated.nncrontab = NncronLexicalState()
            unrelated.nncrontabCache = NncronLexicalCache()
            // 字节零也不继承其它语言的控制状态，显式语言切换必须重建连续证据。
            guard unrelated == SyntaxState() else {
                throw NateError.message("nnCron 不能承接其它语言的词法状态。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                guard state.nncrontab.documentID == nil || state.nncrontab.documentID == snapshot.id,
                    state.nncrontab.revision == nil || state.nncrontab.revision == snapshot.revision,
                    state.nncrontab.sourceIdentity == nil
                        || state.nncrontab.sourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("nnCron 范围与正文身份、修订或原字节不一致。")
                }
            }
            else if state.nncrontab.sourceIdentity != nil {
                throw NateError.message("nnCron 不能失去固定正文来源。")
            }
            else if base > 0 {
                // 真实 EOF 影响候选和字面是否收束，无全文后继资格时不能承接此前的行末状态。
                throw NateError.message("nnCron 续接需要固定完整正文来源。")
            }
            var local = state
            if local.nncrontabCache.range == nil {
                let physical =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard physical.lower == requested.lower, physical.count <= 1_048_576 else {
                    throw NateError.message("nnCron 缺少物理行首或单行超过 1 MiB。")
                }
                let raw = snapshot?.text.bytes(in: physical) ?? Array(text.utf8)
                var scanner = NncronScanner(
                    bytes: raw,
                    rules: rules,
                    budget: budget,
                    state: local.nncrontab,
                    styles: Array(repeating: 0, count: raw.count)
                )
                let classified = try scanner.scan()
                var styles = classified.0
                let ending = classified.1
                if scanner.emitted < raw.count, let snapshot, physical.upper < snapshot.text.byteCount {
                    let next = snapshot.text.lineRange(snapshot.text.lineNumber(at: physical.upper))
                    guard next.lower == physical.upper, next.count <= 1_048_576 else {
                        throw NateError.message("nnCron 后继物理行超过完整前瞻预算。")
                    }
                    // 原生结束字节可由后继词着色，先确认同源前瞻；后继状态不越过当前行发布。
                    styles = try scanner.resolvedStyles(following: snapshot.text.bytes(in: next))
                }
                budget = scanner.budget
                local.nncrontab = ending
                local.nncrontab.documentID = snapshot?.id
                local.nncrontab.revision = snapshot?.revision
                local.nncrontab.sourceIdentity = snapshot?.text.sourceIdentity
                local.nncrontab.resource = rules.identity
                local.nncrontabCache.range = physical
                local.nncrontabCache.tokens = try tokens(
                    raw: raw,
                    styles: styles,
                    base: physical.lower,
                    budget: &budget
                )
            }
            let output = try project(requested, rules: rules, cache: &local.nncrontabCache, budget: &budget)
            // 全行来源、类别及显示容量均确认后才发布，迟到取消不能留下半行结果。
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
