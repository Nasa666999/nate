import Foundation
import NateCore

public struct SearchBookmarkPlan: Sendable {
    public let lines: Set<Int>
    public let unmappedCount: Int
}

extension SearchEngine {
    /// 业务作用：在后台按固定匹配构建完整书签集合，限制跨行扩张并保留调用前的用户书签。
    /// 参数说明:
    /// - result: 绑定同一文档身份和修订的完整有序匹配。
    /// - snapshot: 与匹配坐标一致的原始正文。
    /// - existing: 调用前的书签集合，发布前还需复验当前集合未变化。
    /// - permit: 独立队列中的显式查询权限。
    /// 返回：最多十万行的完整书签集合及无法无损映射的命中数量；错误、取消或超限不返回部分集合。
    public static func bookmarkPlan(
        _ result: SearchResult,
        snapshot: DocumentSnapshot,
        existing: Set<Int>,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> SearchBookmarkPlan {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try bookmarkCheckpoint(permit, deadline: deadline)
        // 书签也是正文坐标，另一文档、旧修订或不完整查询不能沿用当前行号。
        guard result.documentID == snapshot.id, result.revision == snapshot.revision else {
            throw NateError.staleRevision
        }
        guard existing.count <= 100_000, result.hits.count <= 100_000 else {
            throw NateError.message("标记超过 100000 个命中或书签行，请缩小范围；书签未改变。")
        }
        for (index, line) in existing.enumerated() {
            if index & 255 == 0 {
                try bookmarkCheckpoint(permit, deadline: deadline)
            }
            guard line >= 0, line < snapshot.text.lineCount else {
                throw NateError.invalidRange
            }
        }
        var lines = existing
        var previousEnd = 0
        var markedThrough = -1
        var visitedLines = 0
        var unmapped = 0
        for (index, hit) in result.hits.enumerated() {
            if index & 255 == 0 {
                try bookmarkCheckpoint(permit, deadline: deadline)
            }
            let utf16 = hit.utf16Range
            guard utf16.location >= previousEnd, utf16.length >= 0,
                utf16.location <= snapshot.text.utf16Count,
                utf16.length <= snapshot.text.utf16Count - utf16.location
            else {
                throw NateError.invalidRange
            }
            previousEnd = utf16.location + utf16.length
            let mapped = snapshot.text.byteRange(utf16)
            guard mapped == hit.range else {
                throw NateError.invalidRange
            }
            // UTF-16 半代理项没有完整正文范围，单独反馈，不能把邻近标量所在行冒充为命中。
            guard let range = mapped else {
                unmapped += 1
                continue
            }
            let first = max(snapshot.text.lineNumber(at: range.lower), markedThrough + 1)
            let last = snapshot.text.lineNumber(at: max(range.lower, range.upper - 1))
            guard first <= last else {
                continue
            }
            let count = last - first + 1
            // 展开区间之前检查整段行数，一个跨越巨大日志的匹配不能先分配数百万书签再报告超限。
            guard count <= 100_000 - visitedLines else {
                throw NateError.message("匹配覆盖超过 100000 行，请缩小范围；书签未改变。")
            }
            visitedLines += count
            for line in first...last {
                if line & 255 == 0 {
                    try bookmarkCheckpoint(permit, deadline: deadline)
                }
                lines.insert(line)
                guard lines.count <= 100_000 else {
                    throw NateError.message("合并后书签超过 100000 行，请缩小范围；书签未改变。")
                }
            }
            markedThrough = last
        }
        try bookmarkCheckpoint(permit, deadline: deadline)
        return SearchBookmarkPlan(
            lines: lines,
            unmappedCount: unmapped
        )
    }

    /// 业务作用：在命中与行区间内部限制实际标记计算，撤销的队列请求不能继续生成迟到集合。
    /// 参数说明:
    /// - permit: 当前查询仍然有效的显式权限。
    /// - deadline: 本轮标记构建的真实计算截止。
    /// 返回：权限和两秒计算时间都仍有效时继续，否则终止整个未发布集合。
    private static func bookmarkCheckpoint(
        _ permit: @Sendable () -> Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        try Task.checkCancellation()
        // 独立队列没有继承 Swift Task 状态，原查询失权后同样必须停止集合扩张。
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("书签计划超过 2 秒计算预算，请缩小范围；书签未改变。")
        }
    }
}
