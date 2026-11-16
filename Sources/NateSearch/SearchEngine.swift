import Foundation
import NateCore

public enum SearchEngine {
    /// 业务作用：在不可变快照中执行有预算的查找，保留匹配来源和修订。
    /// 参数说明:
    /// - snapshot: 已提交正文快照。
    /// - options: 搜索文本、方言及开关。
    /// - scope: 显式限定范围；选区限制失效时不扩大到全文。
    /// 返回：完整命中列表；错误、取消和超限均以失败返回。
    public static func find(
        in snapshot: DocumentSnapshot,
        options: SearchOptions,
        scope: ByteRange? = nil
    ) throws -> SearchResult {
        guard !options.query.isEmpty else {
            throw NateError.message("请输入查找内容。")
        }
        if options.selectionOnly && (scope == nil || scope?.isEmpty == true) {
            throw NateError.message("选区限制已启用，但没有有效选区。")
        }
        guard let range = snapshot.text.nsRange(scope ?? ByteRange(0, snapshot.text.byteCount)) else {
            throw NateError.invalidRange
        }
        let input = Array(snapshot.text.text().utf16)
        if options.mode != .regex {
            return try LiteralMatcher.find(snapshot: snapshot, input: input, range: range, options: options)
        }
        let compiled: CompiledRegex
        if options.mode == .regex {
            compiled = try RegexParser.compile(options.query)
        }
        else {
            let query = options.mode == .extended ? ExtendedEscapes.decode(options.query) : options.query
            compiled = CompiledRegex(
                root: .sequence(
                    query.utf16.map {
                        .literal($0)
                    }
                ),
                names: [:],
                groups: [:]
            )
        }
        var matcher = CancellableMatcher(
            input: input,
            compiled: compiled,
            limit: options.stepLimit,
            deadline: ContinuousClock.now.advanced(by: .seconds(3))
        )
        var position = range.location
        let end = range.location + range.length
        var hits: [SearchHit] = []
        var lastEnd = position
        while position <= end {
            try matcher.checkpoint()
            matcher.scanStart = lastEnd
            let initial = MatchState(
                position: position,
                start: position,
                sensitive: options.caseSensitive,
                dot: options.dotMatchesNewline
            )
            if let state = try matcher.run(compiled.root, initial).first(where: {
                $0.position <= end
            }) {
                let matched = NSRange(location: state.start, length: state.position - state.start)
                let whole =
                    options.mode == .regex || !options.wholeWord
                    || (matched.location == 0 || !matcher.word(input[matched.location - 1]))
                        && (matched.location + matched.length == input.count
                            || !matcher.word(input[matched.location + matched.length]))
                if whole {
                    var captures = state.captures
                    captures[0] = matched
                    hits.append(
                        SearchHit(
                            utf16Range: matched,
                            range: snapshot.text.byteRange(matched),
                            captures: captures,
                            names: compiled.names
                        )
                    )
                    guard hits.count <= options.maxMatches else {
                        throw NateError.message("命中超过结果上限，请缩小搜索范围。")
                    }
                    lastEnd = state.position
                    position = state.position > position ? state.position : position + 1
                    continue
                }
            }
            position += 1
        }
        return SearchResult(
            documentID: snapshot.id,
            revision: snapshot.revision,
            options: options,
            hits: hits
        )
    }

    /// 业务作用：从固定搜索结果生成原子替换计划，不直接修改正文。
    /// 参数说明:
    /// - result: 对应快照的匹配结果。
    /// - snapshot: 原始正文与捕获上下文。
    /// 返回：所有替换均使用原匹配，不重新搜索本次生成的内容。
    public static func replacementPlan(_ result: SearchResult, snapshot: DocumentSnapshot) throws
        -> [TextEdit]
    {
        guard result.documentID == snapshot.id, result.revision == snapshot.revision else {
            throw NateError.staleRevision
        }
        let units = Array(snapshot.text.text().utf16)
        return try result.hits.map {
            hit in
            guard let range = hit.range else {
                throw NateError.message("命中切开了 UTF-16 代理项，不能无损替换。")
            }
            let value: String
            switch result.options.mode {
            case .literal: value = result.options.replacement
            case .extended: value = ExtendedEscapes.decode(result.options.replacement)
            case .regex: value = try Substitution.expand(result.options.replacement, hit: hit, input: units)
            }
            return TextEdit(range, value)
        }
    }
}
