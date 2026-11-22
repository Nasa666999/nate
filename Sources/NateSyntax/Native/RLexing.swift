import Foundation
import NateCore

struct RLexing {
    let bytes: [UInt8]
    let rules: RRules
    let documentEnd: Bool
    var state: RLexicalState
    var budget: ANSILexingBudget
    var classes: [UInt8]
    var cursor = 0
    var segment = 0

    /// 业务作用：R 完整物理行只扫描一次，显示分段共享同一规则与正文证据。
    /// 参数说明:
    /// - text: 当前请求的完整原标量范围。
    /// - base: 请求的原字节起点。
    /// - snapshot: 提供真实行与来源身份的固定正文。
    /// - rules: 已受容量保护的完整三组词表和样式。
    /// - deadline: 资源、扫描及投影共用的截止。
    /// - state: 连续范围检查点，失败只设置诊断。
    /// 返回：最多 65536 个完整词元；来源或预算不足时不发布部分多行状态。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: RRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 16_777_216)
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.r.nextOffset == nil || state.r.nextOffset == base,
                let rules,
                state.r.resource == nil || state.r.resource == rules.identity
            else {
                throw NateError.message("R 高亮缺少完整规则、连续范围或相同资源身份。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            var current = state.r
            if let snapshot {
                let tree = snapshot.text
                // 修订相同仍须证明同一正文根，多行字面状态不能沿另一份内容继续传播。
                guard current.documentID == nil || current.documentID == snapshot.id,
                    current.revision == nil || current.revision == snapshot.revision,
                    current.sourceIdentity == nil || current.sourceIdentity == tree.sourceIdentity,
                    current.nextOffset != nil || base == 0,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: requested.lower - 1) == 13 && tree.byte(at: requested.lower) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("R 范围与固定正文或检查点来源不一致。")
                }
                current.documentID = snapshot.id
                current.revision = snapshot.revision
                current.sourceIdentity = tree.sourceIdentity
            }
            else if current.sourceIdentity != nil {
                throw NateError.message("R 连续高亮不能失去原固定正文证据。")
            }
            if current.cachedRange == nil {
                let range: ByteRange
                let source: [UInt8]
                if let snapshot, !requested.isEmpty {
                    range = try ANSILexing.physicalRange(requested, tree: snapshot.text, budget: &budget)
                    guard range.lower == requested.lower, range.count <= 1_048_576 else {
                        throw NateError.message("R 高亮缺少物理行首检查点或超过单行 1 MiB。")
                    }
                    source = snapshot.text.bytes(in: range)
                }
                else {
                    range = requested
                    source = Array(text.utf8)
                }
                let initial = current.continuation
                var scanner = RLexing(
                    bytes: source,
                    rules: rules,
                    documentEnd: snapshot.map {
                        range.upper == $0.text.byteCount
                    } ?? true,
                    state: current,
                    budget: budget,
                    classes: Array(repeating: 0, count: source.count)
                )
                try scanner.scan()
                current = scanner.state
                current.cachedRange = range
                current.cachedClasses = scanner.classes
                current.cachedInitialContinuation = initial
                budget = scanner.budget
            }
            guard let range = current.cachedRange, requested.lower >= range.lower,
                requested.upper <= range.upper, current.cachedClasses.count == range.count
            else {
                throw NateError.message("R 显示范围不属于已确认的完整物理行。")
            }
            let tokens = try tokens(
                text,
                base: base,
                origin: range.lower,
                classes: current.cachedClasses,
                styles: rules.styles,
                budget: &budget
            )
            if requested.upper == range.upper {
                current.cachedRange = nil
                current.cachedClasses = []
                current.cachedInitialContinuation = nil
            }
            current.resource = rules.identity
            current.nextOffset = requested.upper
            // 完整分类与标量投影先于状态发布，取消不能留下半份 跨行字面 检查点。
            try budget.check()
            state.r = current
            return tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }
}
