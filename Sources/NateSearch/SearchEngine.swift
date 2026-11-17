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
        try find(
            in: snapshot,
            input: Array(snapshot.text.text().utf16),
            options: options,
            scope: scope,
            firstOnly: false,
            allowEmpty: true
        )
    }

    /// 业务作用：复用固定正文的 UTF-16 投影执行多条结构规则，避免每个名称层级复制全文。
    /// 参数说明:
    /// - snapshot: 已提交正文快照。
    /// - input: 与快照一致的 UTF-16 投影。
    /// - options: 当前表达式与预算。
    /// - scope: 本条规则可消费的字节范围。
    /// - firstOnly: 是否在第一个完整命中后结束。
    /// - allowEmpty: 是否发布零长度命中；结构提取只接受非空名称。
    /// 返回：与同一正文身份关联的搜索结果。
    static func find(
        in snapshot: DocumentSnapshot,
        input: [UInt16],
        options: SearchOptions,
        scope: ByteRange?,
        firstOnly: Bool,
        allowEmpty: Bool
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
        if options.mode != .regex {
            return try LiteralMatcher.find(
                snapshot: snapshot,
                input: input,
                range: range,
                options: options,
                firstOnly: firstOnly
            )
        }
        let compiled = try RegexParser.compile(
            options.query,
            caseSensitive: options.caseSensitive,
            dotMatchesNewline: options.dotMatchesNewline
        )
        var matcher = CancellableMatcher(
            input: input,
            compiled: compiled,
            limit: options.stepLimit,
            deadline: ContinuousClock.now.advanced(by: .seconds(3))
        )
        matcher.softEnd = input.count
        while matcher.softEnd > 0,
            [10, 13, 0x85, 0x2028, 0x2029].contains(input[matcher.softEnd - 1])
        {
            matcher.softEnd -= 1
        }
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
                if !allowEmpty && state.start == state.position {
                    position = max(position + 1, state.position + 1)
                    continue
                }
                // 断言中的起点重置可能形成反向范围，不能把它作为可写命中发布给正文事务。
                guard state.start <= state.position else {
                    throw NateError.message("表达式产生反向匹配范围，请将 \\K 移出前向断言。")
                }
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
                            names: compiled.names.mapValues {
                                ids in
                                ids.first(where: {
                                    captures[$0] != nil
                                }) ?? ids[0]
                            }
                        )
                    )
                    guard hits.count <= options.maxMatches else {
                        throw NateError.message("命中超过结果上限，请缩小搜索范围。")
                    }
                    lastEnd = state.position
                    if firstOnly {
                        break
                    }
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
