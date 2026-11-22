import Foundation
import NateCore

enum MSSQLLexing {
    /// 业务作用：T-SQL 完整物理分类与显示投影共用固定正文、资源和截止，未决片段不提前发布。
    /// 参数说明:
    /// - text: 当前完整显示片段的原文。
    /// - base: 片段在固定正文中的原字节起点。
    /// - snapshot: 全文来源及有界后继证据。
    /// - rules: 已确认完整的 T-SQL 名称和样式。
    /// - deadline: 当前操作的共同截止。
    /// - state: 调用流程独立持有的连续检查点。
    /// 返回：最多 65536 个完整词元；失败只设置诊断，不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: MSSQLRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 16_777_216)
            try budget.check()
            // 完整规则和连续原字节是缓存资格的前提，缺少证据不能沿旧状态解释新片段。
            guard let rules, text.utf8.count <= 1_048_576, base >= 0,
                base <= Int.max - text.utf8.count,
                state.mssqlCache.nextOffset == nil ? base == 0 : state.mssqlCache.nextOffset == base,
                state.mssql.resource == nil || state.mssql.resource == rules.identity
            else {
                throw NateError.message("T-SQL 高亮缺少完整规则或连续原字节。")
            }
            var unrelated = state
            unrelated.mssql = MSSQLLexicalState()
            unrelated.mssqlCache = MSSQLLexicalCache()
            // 即使从字节零重新开始，其它语言的状态也没有授予 T-SQL 解释资格，切换必须显式重建。
            guard unrelated == SyntaxState() else {
                throw NateError.message("T-SQL 不能承接其它语言的词法状态。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                // 显示缓存和前向证据都绑定原正文根，另一修订不能沿用此前确认的未决空白。
                guard state.mssql.documentID == nil || state.mssql.documentID == snapshot.id,
                    state.mssql.revision == nil || state.mssql.revision == snapshot.revision,
                    state.mssql.sourceIdentity == nil
                        || state.mssql.sourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("T-SQL 范围与正文身份、修订或原字节不一致。")
                }
            }
            else if state.mssql.sourceIdentity != nil {
                throw NateError.message("T-SQL 连续投影不能失去固定正文来源。")
            }
            var local = state
            if local.mssqlCache.range == nil {
                let range =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard range.lower == requested.lower, range.count <= 1_048_576 else {
                    throw NateError.message("T-SQL 缺少物理行首或单行超过 1 MiB。")
                }
                let initial = local.mssql
                var scanner = MSSQLScanner(
                    bytes: Array((snapshot?.text.text(in: range) ?? text).utf8),
                    base: range.lower,
                    rules: rules,
                    snapshot: snapshot,
                    budget: budget,
                    state: initial
                )
                try scanner.scan()
                budget = scanner.budget
                local.mssql = scanner.state
                local.mssql.documentID = snapshot?.id
                local.mssql.revision = snapshot?.revision
                local.mssql.sourceIdentity = snapshot?.text.sourceIdentity
                local.mssql.resource = rules.identity
                local.mssqlCache.range = range
                local.mssqlCache.initial = initial
                local.mssqlCache.tokens = try scanner.tokens.map { token in
                    try budget.consume()
                    guard let style = UInt8(token.lexicalStyle.dropFirst(6)) else {
                        throw NateError.message("T-SQL 缓存缺少原生数字类别。")
                    }
                    return MSSQLCachedToken(
                        range: token.range,
                        kind: token.kind,
                        style: style
                    )
                }
            }
            // 另一物理范围的类别不能授予当前片段投影资格，失败仍保留调用前的全部状态。
            guard let range = local.mssqlCache.range,
                requested.lower >= range.lower, requested.upper <= range.upper
            else {
                throw NateError.message("T-SQL 显示范围不属于完整物理分类。")
            }
            let cached = local.mssqlCache.tokens
            var low = 0, high = cached.count
            while low < high {
                let middle = low + (high - low) / 2
                if cached[middle].range.upper <= requested.lower {
                    low = middle + 1
                }
                else {
                    high = middle
                }
            }
            var output: [SyntaxToken] = []
            for token in cached.dropFirst(low) {
                try budget.consume()
                if token.range.lower >= requested.upper {
                    break
                }
                guard let attributes = rules.styles[String(token.style)], output.count < 65_536 else {
                    throw NateError.message("T-SQL 投影超出容量或缺少样式属性。")
                }
                output.append(
                    SyntaxToken(
                        range: ByteRange(
                            max(requested.lower, token.range.lower),
                            min(requested.upper, token.range.upper)
                        ),
                        kind: token.kind,
                        foreground: attributes.foreground,
                        background: attributes.background,
                        fontStyle: attributes.fontStyle,
                        lexicalStyle: "mssql:" + String(token.style)
                    )
                )
            }
            if requested.upper == range.upper {
                local.mssqlCache.range = nil
                local.mssqlCache.tokens = []
                local.mssqlCache.initial = nil
            }
            local.mssqlCache.nextOffset = requested.upper
            // 全部后继证据和显示范围确认后才发布状态，迟到取消不能留下半行颜色。
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
