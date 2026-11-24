import Foundation
import NateCore

struct BashCachedRun: Sendable, Equatable {
    let range: ByteRange
    let style: BashHighlightStyle
}

struct BashLexicalCache: Sendable, Equatable {
    var state = BashHighlightState()
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var identity: Data?
    var nextOffset: Int?
    var range: ByteRange?
    var runs: [BashCachedRun] = []
}

enum BashLexing {
    /// 业务作用：用同一 Bash 来源按完整物理行扫描，并把已确认分类投影到当前实际片段。
    /// 参数说明:
    /// - text: 当前显示的完整原文片段。
    /// - base: 片段在固定正文中的字节起点。
    /// - snapshot: 用于提供真实行首、行尾及原文的固定快照。
    /// - rules: 当前完整十四种样式和命令词表。
    /// - deadline: 当前编辑器或输出操作的共同截止。
    /// - state: 由来源调用流程独立持有的词法证据。
    /// 返回：当前片段完整样式；身份、续接、边界、取消或容量失败时只报告诊断。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: BashHighlightRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 33_554_432)
            try budget.check()
            let count = text.utf8.count
            var cache = state.bash
            var unrelated = state
            unrelated.bash = BashLexicalCache()
            // 缺少连续原字节或规则来源时停在此处，旧引用和 here-document 不能进入另一个快照。
            guard let rules, count <= 1_048_576, base >= 0, base <= Int.max - count,
                unrelated == SyntaxState(), cache.nextOffset ?? 0 == base,
                cache.identity == nil || cache.identity == rules.identity
            else {
                throw NateError.message("Bash 高亮缺少完整规则、连续字节或正确语言来源。")
            }
            let requested = ByteRange(base, base + count)
            let tree: PieceTree
            if let snapshot {
                tree = snapshot.text
                guard cache.identity == nil || cache.sourceIdentity != nil,
                    cache.documentID == nil || cache.documentID == snapshot.id,
                    cache.revision == nil || cache.revision == snapshot.revision,
                    cache.sourceIdentity == nil || cache.sourceIdentity == tree.sourceIdentity,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: requested.lower - 1) == 13 && tree.byte(at: requested.lower) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("Bash 高亮片段与原正文或修订证据不一致。")
                }
                cache.documentID = snapshot.id
                cache.revision = snapshot.revision
                cache.sourceIdentity = tree.sourceIdentity
            }
            else {
                guard base == 0, cache.sourceIdentity == nil, cache.range == nil else {
                    throw NateError.message("Bash 高亮续接需要完整固定正文。")
                }
                tree = PieceTree(text)
            }
            cache.identity = rules.identity
            var cursor = requested.lower
            var output: [SyntaxToken] = []
            while cursor < requested.upper {
                try budget.check()
                if cache.range == nil {
                    let physical = tree.lineRange(tree.lineNumber(at: cursor))
                    guard physical.lower == cursor, physical.count <= 1_048_576, physical.upper > cursor
                    else {
                        throw NateError.message("Bash 高亮需要完整物理行首，单行最多 1 MiB。")
                    }
                    var scanner = BashHighlightScanner(
                        bytes: Array(tree.bytes(in: physical)),
                        keywords: rules.words,
                        budget: budget,
                        state: cache.state
                    )
                    let styles = try scanner.scan()
                    budget = scanner.budget
                    cache.state = scanner.state
                    cache.range = physical
                    cache.runs = try runs(styles, startingAt: physical.lower, text: tree, budget: &budget)
                }
                guard let physical = cache.range, cursor >= physical.lower, cursor < physical.upper else {
                    throw NateError.message("Bash 高亮片段不属于已确认的物理行。")
                }
                let end = min(requested.upper, physical.upper)
                try append(
                    ByteRange(cursor, end),
                    from: cache.runs,
                    rules: rules,
                    into: &output,
                    budget: &budget
                )
                cursor = end
                if end == physical.upper {
                    cache.range = nil
                    cache.runs = []
                }
            }
            cache.nextOffset = requested.upper
            try budget.check()
            state.bash = cache
            return output
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：紧凑保存原生样式段，并核对真实 UTF-8 标量端点。
    /// 参数说明:
    /// - styles: 一行完整原字节的原生样式。
    /// - base: 该物理行的原始起点。
    /// - text: 同一固定正文的字节索引。
    /// - budget: 本次解析共用的扫描与截止预算。
    /// 返回：最多 65536 个连续段；类别或标量端点无效时拒绝整次准备。
    private static func runs(
        _ styles: [UInt8],
        startingAt base: Int,
        text: PieceTree,
        budget: inout ANSILexingBudget
    ) throws -> [BashCachedRun] {
        var result: [BashCachedRun] = []
        var lower = 0
        while lower < styles.count {
            try budget.consume()
            guard let style = BashHighlightStyle(rawValue: styles[lower]), result.count < 65_536 else {
                throw NateError.message("Bash 高亮样式段超过完整容量。")
            }
            var upper = lower + 1
            while upper < styles.count && styles[upper] == styles[lower] {
                try budget.consume()
                upper += 1
            }
            guard text.isBoundary(base + upper) else {
                throw NateError.message("Bash 高亮样式终点切开了原始 Unicode 标量。")
            }
            result.append(BashCachedRun(range: ByteRange(base + lower, base + upper), style: style))
            lower = upper
        }
        return result
    }

    /// 业务作用：把同源完整行样式投影到范围，保留数值类别、颜色与字体属性。
    /// 参数说明:
    /// - range: 当前需要显示的真实原字节。
    /// - runs: 该物理行已经验证的有序样式段。
    /// - rules: 当次固定的完整原生样式资源。
    /// - output: 已准备的结果，同一次调用全部片段共用容量。
    /// - budget: 解析及投影共用的执行额度。
    /// 返回：只追加有完整值的片段；预算、容量或规则不足时抛错。
    private static func append(
        _ range: ByteRange,
        from runs: [BashCachedRun],
        rules: BashHighlightRules,
        into output: inout [SyntaxToken],
        budget: inout ANSILexingBudget
    ) throws {
        var lower = 0
        var upper = runs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if runs[middle].range.upper <= range.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        for run in runs.dropFirst(lower) {
            try budget.consume()
            guard run.range.lower < range.upper else {
                break
            }
            let start = max(run.range.lower, range.lower)
            let end = min(run.range.upper, range.upper)
            let number = String(run.style.rawValue)
            guard output.count < 65_536, let style = rules.styles[number] else {
                throw NateError.message("Bash 高亮投影缺少完整样式或超过 65536 段。")
            }
            let kind: SyntaxKind
            switch run.style {
            case .comment: kind = .comment
            case .number: kind = .number
            case .keyword: kind = .keyword
            case .punctuation: kind = .punctuation
            case .string, .literal, .parameter, .command, .hereDelimiter, .hereText: kind = .string
            default: kind = .text
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(start, end),
                    kind: kind,
                    foreground: style.foreground,
                    background: style.background,
                    fontStyle: style.fontStyle,
                    lexicalStyle: "bash:" + number
                )
            )
        }
    }
}
