import Foundation
import NateCore

extension SearchEngine {
    /// 业务作用：从当前选区边界查找首个候选，只有本方向没有命中时才按独立全文范围循环。
    /// 参数说明:
    /// - snapshot: 导航开始时固定的正文。
    /// - options: 搜索条件及循环开关；导航不使用批量选区限制。
    /// - selection: 当前视图的连续主选区。
    /// - previous: 是否反向查找；正则反向明确拒绝。
    /// - continuingEmpty: 是否继续同一修订、条件和视图中已经选中的空命中。
    /// 返回：至多一个命中，保留真实调用起点的捕获与替换上下文；取消和超限明确失败。
    public static func navigate(
        in snapshot: DocumentSnapshot,
        options: SearchOptions,
        selection: ByteRange,
        previous: Bool = false,
        continuingEmpty: Bool = false
    ) throws -> SearchResult {
        guard let selected = snapshot.text.nsRange(selection) else {
            throw NateError.invalidRange
        }
        guard options.mode != .regex || !previous else {
            throw NateError.message("正则默认禁用反向搜索；请使用正向匹配导航。")
        }
        var effective = options
        effective.selectionOnly = false
        let input = Array(snapshot.text.text().utf16)
        let origin = previous ? selected.location : selected.location + selected.length
        let scope =
            previous ? ByteRange(0, selection.lower) : ByteRange(selection.upper, snapshot.text.byteCount)
        /// 业务作用：执行单方向的一段导航，循环段保留独立的搜索起点与全文上下文。
        /// 参数说明:
        /// - scope: 本段允许消费的正文范围。
        /// - origin: 本段开始搜索的 UTF-16 位置。
        /// - continuing: 是否排除刚选中的起点空命中。
        /// 返回：首个匹配即结束，不因后续昂贵分支影响已找到的结果。
        func leg(_ scope: ByteRange, origin: Int, continuing: Bool) throws -> SearchResult {
            try Task.checkCancellation()
            if previous, let range = snapshot.text.nsRange(scope) {
                return try LiteralMatcher.find(
                    snapshot: snapshot,
                    input: input,
                    range: range,
                    options: effective,
                    firstOnly: true,
                    backwards: true
                )
            }
            // 从 CRLF 中间开始时本段禁用空结果，避免把同一逻辑换行拆成两个可见停靠点。
            let betweenCRLF =
                origin > 0 && origin < input.count && input[origin - 1] == 13 && input[origin] == 10
            return try find(
                in: snapshot,
                input: input,
                options: effective,
                scope: scope,
                firstOnly: true,
                allowEmpty: !betweenCRLF,
                enumeration: .navigation,
                allowEmptyAtStart: !continuing
            )
        }
        let result = try leg(scope, origin: origin, continuing: continuingEmpty)
        if !result.hits.isEmpty || !effective.wrap {
            return result
        }
        // 循环是一次新的全文搜索，不能把目标终点截在原光标处而改变断言和跨光标命中。
        return try leg(
            ByteRange(0, snapshot.text.byteCount),
            origin: previous ? input.count : 0,
            continuing: false
        )
    }

    /// 业务作用：单次替换只复验当前完整选区，不为其他命中预先展开替换文本。
    /// 参数说明:
    /// - snapshot: 当前正文快照。
    /// - options: 当前搜索和替换条件。
    /// - selection: 用户准备替换的完整匹配范围，空匹配也可复验。
    /// 返回：选区恰好匹配时保留一个命中，否则返回空结果，不修改正文。
    public static func selectedMatch(
        in snapshot: DocumentSnapshot,
        options: SearchOptions,
        selection: ByteRange
    ) throws -> SearchResult {
        guard snapshot.text.nsRange(selection) != nil else {
            throw NateError.invalidRange
        }
        var effective = options
        effective.selectionOnly = false
        let result = try find(
            in: snapshot,
            input: Array(snapshot.text.text().utf16),
            options: effective,
            scope: ByteRange(selection.lower, snapshot.text.byteCount),
            firstOnly: true,
            allowEmpty: true,
            enumeration: .navigation
        )
        return SearchResult(
            documentID: snapshot.id,
            revision: snapshot.revision,
            options: effective,
            hits: result.hits.first?.range == selection ? result.hits : []
        )
    }
}
