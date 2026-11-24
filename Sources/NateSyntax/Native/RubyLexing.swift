import Foundation
import NateCore

struct RubyStyleRun: Equatable, Sendable {
    let range: ByteRange
    let style: RubyHighlightStyle
    let insideInterpolation: Bool
}

struct RubyLexicalCache: Equatable, Sendable {
    var lexer = RubyIndentationLexer()
    var document: UUID?
    var revision: UInt64?
    var root: UUID?
    var rules: Data?
    var next = 0
    var physical: ByteRange?
    var runs: [RubyStyleRun] = []
}

enum RubyLexing {
    /// 业务作用：按固定正文的真实物理行识别 Ruby 字面和代码，并只呈现请求的原始字节。
    /// 参数说明:
    /// - input: 与固定正文一致的当前片段。
    /// - base: 片段的真实起点。
    /// - snapshot: 当前任务的固定正文字节和身份。
    /// - rules: 已完整确认的有效 Ruby 资源。
    /// - deadline: 当前操作共同截止。
    /// - state: 调用流程保存的真实词法传播状态。
    /// 返回：完整有界样式；来源、字节、截止、取消或容量不足时保留原状态并给出诊断。
    static func highlight(
        _ input: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        rules: RubyHighlightRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 33_554_432)
            let length = input.utf8.count
            var cache = state.ruby
            var unrelated = state
            unrelated.ruby = RubyLexicalCache()
            // 真实文档、资源或连续范围失效时，旧字面不能传播到另一份正文。
            guard let rules, unrelated == SyntaxState(), base >= 0, base <= Int.max - length,
                length <= 1_048_576, cache.next == base, cache.rules == nil || cache.rules == rules.source
            else {
                throw NateError.message("Ruby 高亮缺少完整词法资源或连续原文。")
            }
            let requested = ByteRange(base, base + length)
            let tree: PieceTree
            if let snapshot {
                tree = snapshot.text
                guard
                    cache.root == nil
                        || (cache.document == snapshot.id && cache.revision == snapshot.revision
                            && cache.root == tree.sourceIdentity),
                    cache.rules == nil || cache.root != nil,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: base - 1) == 13 && tree.byte(at: base) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(input.utf8)
                else {
                    throw NateError.message("Ruby 高亮片段与固定的实际原文或修订不一致。")
                }
                cache.document = snapshot.id
                cache.revision = snapshot.revision
                cache.root = tree.sourceIdentity
            }
            else {
                guard cache.rules == nil else {
                    throw NateError.message("Ruby 词法续接需要完整固定正文。")
                }
                tree = PieceTree(input)
            }
            try budget.check()
            cache.rules = rules.source
            var cursor = requested.lower
            var output: [SyntaxToken] = []
            while cursor < requested.upper {
                try budget.check()
                if cache.physical == nil {
                    try prepareLine(at: cursor, tree: tree, rules: rules, cache: &cache, budget: &budget)
                }
                guard let physical = cache.physical, physical.lower <= cursor, cursor < physical.upper else {
                    throw NateError.message("Ruby 高亮需要实际物理行边界。")
                }
                let end = min(physical.upper, requested.upper)
                try append(
                    ByteRange(cursor, end),
                    from: cache.runs,
                    rules: rules,
                    to: &output,
                    budget: &budget
                )
                cursor = end
                if cursor == physical.upper {
                    cache.physical = nil
                    cache.runs.removeAll()
                }
            }
            try budget.check()
            cache.next = requested.upper
            state.ruby = cache
            return output
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：只对完整物理行解释字面与真实换行，对后续分段保留同一原字节证据。
    /// 参数说明:
    /// - offset: 需要开始传播的物理行首。
    /// - tree: 固定来源的完整原文。
    /// - rules: 当前已确认的原词表和样式。
    /// - cache: 本次准备尚未发布的词法状态及缓存。
    /// - budget: 词法读取与样式投影使用的共同额度。
    /// 返回：将已确认的行样式写入候选缓存，扩展字节样式遵循完整标量。
    private static func prepareLine(
        at offset: Int,
        tree: PieceTree,
        rules: RubyHighlightRules,
        cache: inout RubyLexicalCache,
        budget: inout ANSILexingBudget
    ) throws {
        let line = tree.lineNumber(at: offset)
        let physical = tree.lineRange(line)
        guard physical.lower == offset, physical.upper > offset, physical.count <= 1_048_576 else {
            throw NateError.message("Ruby 高亮单个完整物理行最多 1 MiB。")
        }
        let body = tree.lineRange(line, includeEnding: false)
        let bytes = tree.bytes(in: physical)
        let row = try cache.lexer.row(Array(bytes.prefix(body.count)), highlightInterpolations: true) {
            try budget.consume()
        }
        var words = RubyHighlightWords()
        let (styles, opaque) = try words.styles(
            for: row,
            bytes: bytes,
            keywords: rules.keywords,
            budget: &budget
        )
        var runs: [RubyStyleRun] = []
        var start = 0
        while start < styles.count {
            try budget.consume()
            let style = styles[start]
            let insideInterpolation = !opaque.isEmpty && opaque[start]
            var end = start + 1
            while end < styles.count,
                bytes[end] & 0xC0 == 0x80
                    || (styles[end] == style && (opaque.isEmpty || opaque[end] == insideInterpolation))
            {
                try budget.consume()
                end += 1
            }
            guard runs.count < 65_536 else {
                throw NateError.message("Ruby 高亮物理行的连续样式超过 65536 段。")
            }
            runs.append(
                RubyStyleRun(
                    range: ByteRange(offset + start, offset + end),
                    style: style,
                    insideInterpolation: insideInterpolation
                )
            )
            start = end
        }
        cache.physical = physical
        cache.runs = runs
    }

    /// 业务作用：只投影和当前请求相交的连续段，固定数字类别可被主题独立覆盖。
    /// 参数说明:
    /// - requested: 由同一原文确认的实际输出范围。
    /// - runs: 该行按原字节有序的完整样式。
    /// - rules: 当前准备过程固定的资源。
    /// - output: 尚未发布的同批词元。
    /// - budget: 扫描与投影共用的额度。
    /// 返回：向候选数组追加完整可用的样式；超量或资源缺席时抛错。
    private static func append(
        _ requested: ByteRange,
        from runs: [RubyStyleRun],
        rules: RubyHighlightRules,
        to output: inout [SyntaxToken],
        budget: inout ANSILexingBudget
    ) throws {
        var lower = 0
        var upper = runs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if runs[middle].range.upper <= requested.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        for run in runs.dropFirst(lower) {
            try budget.consume()
            if run.range.lower >= requested.upper {
                break
            }
            let number = String(run.style.rawValue)
            guard output.count < 65_536, let style = rules.styles[number] else {
                throw NateError.message("Ruby 高亮缺少实际样式或超出 65536 个投影段。")
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(
                        max(requested.lower, run.range.lower),
                        min(requested.upper, run.range.upper)
                    ),
                    kind: run.style.kind,
                    foreground: style.foreground,
                    background: style.background,
                    fontStyle: style.fontStyle,
                    lexicalStyle: (run.insideInterpolation ? "ruby:interpolation:" : "ruby:") + number,
                    nativeStyle: run.style.rawValue
                )
            )
        }
    }
}
