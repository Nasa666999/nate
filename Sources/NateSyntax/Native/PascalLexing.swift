import Foundation
import NateCore

enum PascalLexing {
    /// 业务作用：Pascal 完整物理行先分类再投影，声明、汇编及字面状态只沿同一原文连续传播。
    /// 参数说明:
    /// - text: 本次展示片段的原文。
    /// - base: 展示片段的原字节起点。
    /// - snapshot: 当前固定完整原文。
    /// - rules: 完整 Pascal 单组词表与样式。
    /// - deadline: 所属操作的共同截止。
    /// - state: 由当前调用流程独立持有的连续状态。
    /// 返回：完整片段的有限样式；失败只设置诊断，正文与历史不变。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: PascalRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 33_554_432)
            try budget.check()
            // 规则与连续字节共同授予状态资格，缺少来源时不得把另一行的声明或字面状态继续开放。
            guard let rules, text.utf8.count <= 1_048_576, base >= 0,
                base <= Int.max - text.utf8.count,
                state.pascalCache.nextOffset == nil ? base == 0 : state.pascalCache.nextOffset == base,
                state.pascal.resource == nil || state.pascal.resource == rules.identity
            else {
                throw NateError.message("Pascal 高亮缺少完整规则或连续原字节。")
            }
            var unrelated = state
            unrelated.pascal = PascalLexicalState()
            unrelated.pascalCache = PascalLexicalCache()
            // 字节零也不继承其它语言的控制状态，显式语言切换必须重建连续证据。
            guard unrelated == SyntaxState() else {
                throw NateError.message("Pascal 不能承接其它语言的词法状态。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                guard state.pascal.documentID == nil || state.pascal.documentID == snapshot.id,
                    state.pascal.revision == nil || state.pascal.revision == snapshot.revision,
                    state.pascal.sourceIdentity == nil
                        || state.pascal.sourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("Pascal 范围与正文身份、修订或原字节不一致。")
                }
            }
            else if state.pascal.sourceIdentity != nil {
                throw NateError.message("Pascal 不能失去固定正文来源。")
            }
            else if base > 0 {
                // 真实 EOF 影响候选和字面是否收束，无全文后继资格时不能承接此前的行末状态。
                throw NateError.message("Pascal 续接需要固定完整正文来源。")
            }
            var local = state
            if local.pascalCache.range == nil {
                let physical =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard physical.lower == requested.lower, physical.count <= 1_048_576 else {
                    throw NateError.message("Pascal 缺少物理行首或单行超过 1 MiB。")
                }
                let raw = snapshot?.text.bytes(in: physical) ?? Array(text.utf8)
                var scanner = PascalScanner(
                    bytes: raw,
                    base: physical.lower,
                    snapshot: snapshot,
                    rules: rules,
                    documentEnd: snapshot.map {
                        physical.upper == $0.text.byteCount
                    } ?? true,
                    budget: budget,
                    state: local.pascal,
                    styles: Array(repeating: 0, count: raw.count)
                )
                let (styles, ending) = try scanner.scan()
                budget = scanner.budget
                local.pascal = ending
                local.pascal.documentID = snapshot?.id
                local.pascal.revision = snapshot?.revision
                local.pascal.sourceIdentity = snapshot?.text.sourceIdentity
                local.pascal.resource = rules.identity
                local.pascalCache.range = physical
                local.pascalCache.tokens = try tokens(
                    raw: raw,
                    styles: styles,
                    base: physical.lower,
                    budget: &budget
                )
            }
            let output = try project(requested, rules: rules, cache: &local.pascalCache, budget: &budget)
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
