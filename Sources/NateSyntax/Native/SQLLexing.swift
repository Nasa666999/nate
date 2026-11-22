import Foundation
import NateCore

enum SQLLexing {
    /// 业务作用：SQL 完整物理分类与显示投影共用固定正文、资源和截止，类别完整后才发布。
    /// 参数说明:
    /// - text: 当前完整显示片段的原文。
    /// - base: 片段在固定正文中的原字节起点。
    /// - snapshot: 全文来源及有界后继证据。
    /// - rules: 已确认完整的 SQL 名称和样式。
    /// - deadline: 当前操作的共同截止。
    /// - state: 调用流程独立持有的连续检查点。
    /// 返回：最多 65536 个完整词元；失败只设置诊断，不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: SQLRules?,
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
                state.sqlCache.nextOffset == nil ? base == 0 : state.sqlCache.nextOffset == base,
                state.sql.resource == nil || state.sql.resource == rules.identity
            else {
                throw NateError.message("SQL 高亮缺少完整规则或连续原字节。")
            }
            var unrelated = state
            unrelated.sql = SQLLexicalState()
            unrelated.sqlCache = SQLLexicalCache()
            // 即使从字节零重新开始，其它语言的状态也没有授予 SQL 解释资格，切换必须显式重建。
            guard unrelated == SyntaxState() else {
                throw NateError.message("SQL 不能承接其它语言的词法状态。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                // 显示缓存和跨行引号都绑定原正文根，另一修订不能沿用此前确认的边界。
                guard state.sql.documentID == nil || state.sql.documentID == snapshot.id,
                    state.sql.revision == nil || state.sql.revision == snapshot.revision,
                    state.sql.sourceIdentity == nil
                        || state.sql.sourceIdentity == snapshot.text.sourceIdentity,
                    snapshot.text.isBoundary(requested.lower), snapshot.text.isBoundary(requested.upper),
                    !(snapshot.text.byte(at: requested.lower - 1) == 13
                        && snapshot.text.byte(at: requested.lower) == 10),
                    !(snapshot.text.byte(at: requested.upper - 1) == 13
                        && snapshot.text.byte(at: requested.upper) == 10),
                    snapshot.text.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("SQL 范围与正文身份、修订或原字节不一致。")
                }
            }
            else if state.sql.sourceIdentity != nil {
                throw NateError.message("SQL 连续投影不能失去固定正文来源。")
            }
            else if base > 0 {
                // 缺少全文来源时，已按 EOF 分类的名称不能继续拼接，CRLF 也不能分属两个调用。
                guard state.sql.physicalBoundary,
                    !(state.sql.previousScalar == 13 && text.utf8.first == 10)
                else {
                    throw NateError.message("SQL 连续范围缺少完整物理边界来源。")
                }
            }
            var local = state
            if local.sqlCache.range == nil {
                let range =
                    try snapshot.map {
                        try ANSILexing.physicalRange(requested, tree: $0.text, budget: &budget)
                    } ?? requested
                guard range.lower == requested.lower, range.count <= 1_048_576 else {
                    throw NateError.message("SQL 缺少物理行首或单行超过 1 MiB。")
                }
                let initial = local.sql
                var scanner = SQLScanner(
                    bytes: Array((snapshot?.text.text(in: range) ?? text).utf8),
                    base: range.lower,
                    rules: rules,
                    snapshot: snapshot,
                    budget: budget,
                    state: initial
                )
                try scanner.scan()
                budget = scanner.budget
                local.sql = scanner.state
                local.sql.documentID = snapshot?.id
                local.sql.revision = snapshot?.revision
                local.sql.sourceIdentity = snapshot?.text.sourceIdentity
                local.sql.resource = rules.identity
                local.sqlCache.range = range
                local.sqlCache.initial = initial
                local.sqlCache.tokens = try scanner.tokens.map { token in
                    try budget.consume()
                    guard let style = UInt8(token.lexicalStyle.dropFirst(4)) else {
                        throw NateError.message("SQL 缓存缺少原生数字类别。")
                    }
                    return SQLCachedToken(
                        range: token.range,
                        kind: token.kind,
                        style: style
                    )
                }
            }
            // 另一物理范围的类别不能授予当前片段投影资格，失败仍保留调用前的全部状态。
            guard let range = local.sqlCache.range,
                requested.lower >= range.lower, requested.upper <= range.upper
            else {
                throw NateError.message("SQL 显示范围不属于完整物理分类。")
            }
            let cached = local.sqlCache.tokens
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
                    throw NateError.message("SQL 投影超出容量或缺少样式属性。")
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
                        lexicalStyle: "sql:" + String(token.style)
                    )
                )
            }
            if requested.upper == range.upper {
                local.sqlCache.range = nil
                local.sqlCache.tokens = []
                local.sqlCache.initial = nil
            }
            local.sqlCache.nextOffset = requested.upper
            // 全部字面边界和显示范围确认后才发布状态，迟到取消不能留下半行颜色。
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
