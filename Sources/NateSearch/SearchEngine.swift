import Foundation
import NateCore

public enum SearchEngine {
    /// 业务作用：在不可变快照中执行有预算的查找，保留匹配来源和修订。
    /// 参数说明:
    /// - snapshot: 已提交正文快照。
    /// - options: 搜索文本、方言及开关。
    /// - scope: 显式限定范围；选区限制失效时不扩大到全文。
    /// - enumeration: 批量、导航或排除空匹配的继续规则。
    /// - permit: 显式调用权限，为假时取消底层计算，适用于独立 I/O 队列。
    /// 返回：完整命中列表；错误、取消和超限均以失败返回。
    public static func find(
        in snapshot: DocumentSnapshot,
        options: SearchOptions,
        scope: ByteRange? = nil,
        enumeration: SearchEnumeration = .batch,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SearchResult {
        try Task.checkCancellation()
        // 原请求撤销后不再建立全文派生投影，避免迟到工作继续增加快照的内存占用。
        guard permit() else {
            throw CancellationError()
        }
        try options.validateInput()
        return try find(
            in: snapshot,
            input: Array(snapshot.text.text().utf16),
            options: options,
            scope: scope,
            firstOnly: false,
            allowEmpty: true,
            enumeration: enumeration,
            permit: permit
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
    /// - enumeration: 相邻匹配和末尾边界的继续规则。
    /// - limitContextToScope: 为真时断言和全文终点受目标终点约束；结构规则可保留完整正文上下文。
    /// - allowEmptyAtStart: 是否接受本次调用起点的空匹配；已选中的空命中继续导航时关闭。
    /// - permit: 在解析、匹配及边界内持续复验的显式调用权限。
    /// 返回：与同一正文身份关联的搜索结果。
    static func find(
        in snapshot: DocumentSnapshot,
        input: [UInt16],
        options: SearchOptions,
        scope: ByteRange?,
        firstOnly: Bool,
        allowEmpty: Bool,
        enumeration: SearchEnumeration = .batch,
        limitContextToScope: Bool = true,
        allowEmptyAtStart: Bool = true,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SearchResult {
        try Task.checkCancellation()
        // 共享投影调用也可能来自独立队列，不能因跳过外层入口而跳过权限门禁。
        guard permit() else {
            throw CancellationError()
        }
        try options.validateInput()
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
                firstOnly: firstOnly,
                permit: permit
            )
        }
        let compiled = try RegexParser.compile(
            options.query,
            caseSensitive: options.caseSensitive,
            dotMatchesNewline: options.dotMatchesNewline,
            permit: permit
        )
        var matcher = CancellableMatcher(
            input: input,
            compiled: compiled,
            limit: options.stepLimit,
            deadline: ContinuousClock.now.advanced(by: .seconds(3)),
            permit: permit
        )
        let end = range.location + range.length
        let captureCount = compiled.groups.keys.max() ?? 0
        matcher.contextEnd = limitContextToScope ? end : input.count
        matcher.softEnd = matcher.inputEnd
        while matcher.softEnd > 0,
            [10, 13, 0x85, 0x2028, 0x2029].contains(input[matcher.softEnd - 1])
        {
            matcher.softEnd -= 1
        }
        var position = range.location
        var hits: [SearchHit] = []
        var callStart = position
        var searchStart = position
        var previousEmpty: Bool? = allowEmptyAtStart ? nil : true
        let policy = allowEmpty ? enumeration : .nonEmpty
        while position <= end {
            try matcher.checkpoint()
            matcher.scanStart = searchStart
            matcher.restart = .next
            let initial = MatchState(
                position: position,
                start: position,
                sensitive: options.caseSensitive,
                dot: options.dotMatchesNewline
            )
            if let state = try matcher.firstMatch(compiled.root, initial, end: end) {
                let empty = state.start == state.position
                let allowedEmpty =
                    policy != .nonEmpty
                    && (previousEmpty == nil
                        || (policy == .navigation && previousEmpty == false) || state.start > callStart)
                if empty && !allowedEmpty {
                    position = RegexProgress.next(input, after: state.start)
                    // 拒绝空结果后按新起点重新搜索，\G 和替换前文必须随本轮真正起点一起推进。
                    searchStart = position
                    continue
                }
                // 断言中的起点重置可能形成反向范围，不能把它作为可写命中发布给正文事务。
                guard state.start <= state.position else {
                    throw NateError.message("表达式产生反向匹配范围，请将 \\K 移出前向断言。")
                }
                // 起点重置不能让结果退回本轮授权范围之前，否则不能生成可靠的继续位置和替换计划。
                guard state.start >= searchStart else {
                    throw NateError.message("表达式将匹配起点重置到本轮搜索起点之前。")
                }
                let matched = NSRange(
                    location: state.start,
                    length: state.position - state.start
                )
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
                            },
                            context: SearchMatchContext(
                                prefix: NSRange(
                                    location: searchStart,
                                    length: state.start - searchStart
                                ),
                                suffix: NSRange(
                                    location: state.position,
                                    length: matcher.inputEnd - state.position
                                )
                            ),
                            captureCount: captureCount,
                            lastClosedCapture: state.lastClosedCapture
                        )
                    )
                    guard hits.count <= options.maxMatches else {
                        throw NateError.message("命中超过结果上限，请缩小搜索范围。")
                    }
                    if firstOnly {
                        break
                    }
                    if policy != .navigation && state.position == end {
                        break
                    }
                    previousEmpty = empty
                    position = state.position
                    callStart = position
                    searchStart = position
                    continue
                }
            }
            switch matcher.restart {
            case .next:
                position += 1
            case .position(let next):
                position = max(position + 1, next)
            case .stop:
                position = end + 1
            }
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
    /// - permit: 调用方仍然持有的替换计划权限。
    /// 返回：所有替换均使用原匹配，不重新搜索生成内容；范围、取消、格式及膨胀预算失败时不产生部分计划。
    public static func replacementPlan(
        _ result: SearchResult,
        snapshot: DocumentSnapshot,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws
        -> [TextEdit]
    {
        guard result.documentID == snapshot.id, result.revision == snapshot.revision else {
            throw NateError.staleRevision
        }
        guard result.options.replacement.utf8.count <= ReplacementBudget.formatLimit else {
            throw NateError.message("替换格式超过 1 MiB；请输入完整且不超过上限的格式。")
        }
        var budget = ReplacementBudget(permit: permit)
        try budget.checkpoint(force: true)
        var edits: [TextEdit] = []
        var outputBytes = 0
        var removedBytes = 0
        var previousEnd = 0
        let plain =
            result.options.mode == .extended
            ? ExtendedEscapes.decode(result.options.replacement) : result.options.replacement
        for hit in result.hits {
            try budget.checkpoint(force: true)
            guard let range = hit.range, snapshot.text.byteRange(hit.utf16Range) == range else {
                throw NateError.message("命中切开了 UTF-16 代理项，不能无损替换。")
            }
            // 所有范围属于同一原快照且必须有序不交叠，才能准确预留最终正文而不重复扣除旧内容。
            guard range.lower >= previousEnd else {
                throw NateError.message("替换命中范围交叠或顺序失效，未生成计划。")
            }
            previousEnd = range.upper
            // 捕获和前后文也会生成正文，任何半代理项都不能经替代字符进入可提交的替换计划。
            let contexts =
                hit.context.map {
                    [$0.prefix, $0.suffix]
                } ?? []
            guard
                (Array(hit.captures.values) + contexts).allSatisfy({
                    snapshot.text.byteRange($0) != nil
                })
            else {
                throw NateError.message("捕获或替换上下文切开了 UTF-16 代理项，不能无损替换。")
            }
            let value: String
            switch result.options.mode {
            case .literal, .extended:
                value = plain
            case .regex:
                value = try Substitution.expand(
                    result.options.replacement,
                    hit: hit,
                    text: snapshot.text,
                    outputLimit: min(
                        ReplacementBudget.itemLimit,
                        ReplacementBudget.outputLimit - outputBytes
                    ),
                    budget: &budget
                )
            }
            let count = value.utf8.count
            // 先按差额校验再相加，输出和正文预算不会因整数溢出或大量小命中被绕过。
            guard count <= ReplacementBudget.itemLimit,
                count <= ReplacementBudget.outputLimit - outputBytes
            else {
                throw NateError.message("替换输出超过单项 64 MiB 或总量 256 MiB 预算。")
            }
            outputBytes += count
            removedBytes += range.count
            edits.append(TextEdit(range, value))
        }
        guard
            edits.isEmpty
                || snapshot.text.byteCount - removedBytes <= ReplacementBudget.documentLimit - outputBytes
        else {
            throw NateError.message("替换后的正文超过 1 GiB 预算，未修改原文。")
        }
        try budget.checkpoint(force: true)
        return edits
    }
}
