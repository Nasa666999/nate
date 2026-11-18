import Foundation
import NateCore
import NateStorage

enum SearchResultLineContent: Sendable {
    case buffer(PieceTree)
    case disk(URL, baseline: DiskBaseline, encoding: TextEncoding)
}

struct SearchResultLineSource: Sendable {
    let content: SearchResultLineContent
    let ranges: [ByteRange]
}

enum SearchResultLineExport {
    /// 业务作用：完整源行复制在后台复验磁盘证据并按真实逻辑行去重，预览截断不影响输出正文。
    /// 参数说明:
    /// - sources: 已固定内存修订或磁盘基线的来源组与完整匹配范围。
    /// - access: 与普通文件打开相同的协调读取入口。
    /// - catalog: 搜索时使用的严格传统编码映射。
    /// - token: 父操作的实际取消权限。
    /// 返回：最多十万行、64 MiB 的完整原文，以 LF 连接；读取、过期、取消或预算失败不返回部分文本。
    static func prepare(
        _ sources: [SearchResultLineSource],
        access: CoordinatedFileAccess,
        catalog: LegacyCodecCatalog?,
        token: CancellationToken
    ) throws -> (text: String, lines: Int) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var remaining = 64 * 1024 * 1024
        var readRemaining = 1024 * 1024 * 1024
        var lineCount = 0
        var output = ""
        for source in sources {
            try checkpoint(token, deadline: deadline)
            let tree: PieceTree
            switch source.content {
            case .buffer(let snapshot): tree = snapshot
            case .disk(let url, let baseline, let encoding):
                let loaded = try access.load(
                    url,
                    encoding: encoding,
                    catalog: catalog,
                    maximumBytes: readRemaining,
                    permit: {
                        !token.isCancelled && ContinuousClock.now < deadline
                    }
                )
                // 只接受搜索时的完整字节和解码规则，当前打开缓冲区不替代磁盘来源。
                guard loaded.baseline == baseline, loaded.encoding == encoding else {
                    throw NateError.message("命中行的磁盘来源已过期，请重新搜索；剪贴板保留。")
                }
                readRemaining -= loaded.originalBytes.count
                tree = loaded.tree
            }
            let intervals = try lineIntervals(source.ranges, tree: tree, token: token, deadline: deadline)
            for interval in intervals {
                let count = interval.upperBound - interval.lowerBound + 1
                guard count <= 100_000 - lineCount else {
                    throw NateError.message("复制命中行超过十万行，请缩小所选结果；剪贴板保留。")
                }
                lineCount += count
                for line in interval {
                    try checkpoint(token, deadline: deadline)
                    let range = tree.lineRange(line, includeEnding: false)
                    guard range.count < remaining else {
                        throw NateError.message("复制命中行超过 64 MiB，请缩小所选结果；剪贴板保留。")
                    }
                    remaining -= range.count + 1
                    var offset = range.lower
                    while offset < range.upper {
                        try checkpoint(token, deadline: deadline)
                        var end = min(range.upper, offset + 65_536)
                        while end > offset && !tree.isBoundary(end) {
                            end -= 1
                        }
                        output += tree.text(in: ByteRange(offset, end))
                        offset = end
                    }
                    output += "\n"
                }
            }
        }
        try checkpoint(token, deadline: deadline)
        guard lineCount > 0 else {
            throw NateError.message("当前没有可复制的命中行。")
        }
        return (output, lineCount)
    }

    /// 业务作用：重叠的跨行匹配先合并行区间，重复命中不能反复展开同一大段正文而耗尽执行预算。
    /// 参数说明:
    /// - ranges: 一个来源组内的完整匹配范围。
    /// - tree: 与原搜索证据一致的固定正文。
    /// - token: 当前复制操作的取消权限。
    /// - deadline: 所有来源共用的截止时刻。
    /// 返回：按源行顺序排列且互不重叠的行区间，越界或非字符边界整体失败。
    private static func lineIntervals(
        _ ranges: [ByteRange],
        tree: PieceTree,
        token: CancellationToken,
        deadline: ContinuousClock.Instant
    ) throws -> [ClosedRange<Int>] {
        var intervals: [ClosedRange<Int>] = []
        for range in ranges {
            try checkpoint(token, deadline: deadline)
            // 失效或切开字符的偏移不能夹到邻近行，否则复制出的正文将不再属于原匹配。
            guard tree.isBoundary(range.lower), tree.isBoundary(range.upper) else {
                throw NateError.message("命中范围与源正文不一致，请重新搜索；剪贴板保留。")
            }
            let first = tree.lineNumber(at: range.lower)
            let last = tree.lineNumber(at: range.isEmpty ? range.lower : range.upper - 1)
            intervals.append(first...last)
        }
        var comparisons = 0
        try intervals.sort {
            left,
            right in
            comparisons += 1
            if comparisons & 1023 == 0 {
                try checkpoint(token, deadline: deadline)
            }
            return left.lowerBound == right.lowerBound
                ? left.upperBound < right.upperBound : left.lowerBound < right.lowerBound
        }
        var merged: [ClosedRange<Int>] = []
        for interval in intervals {
            try checkpoint(token, deadline: deadline)
            if let last = merged.last, interval.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            }
            else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// 业务作用：来源读取、行合并和分块正文复制共享取消与截止，过期操作不能继续占用后台队列。
    /// 参数说明:
    /// - token: 实际复制操作的取消令牌。
    /// - deadline: 整轮复制的共享截止时刻。
    /// 返回：仍有权限与时间时继续，否则终止整份输出。
    private static func checkpoint(_ token: CancellationToken, deadline: ContinuousClock.Instant) throws {
        try token.check()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("复制命中行超过五秒，请缩小所选结果；剪贴板保留。")
        }
    }
}
