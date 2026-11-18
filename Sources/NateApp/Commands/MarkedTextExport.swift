import Foundation
import NateCore

enum MarkedTextExport {
    /// 业务作用：复制标记的实际正文片段，重叠覆盖只输出一次，不把预览摘要或空匹配伪造成正文。
    /// 参数说明:
    /// - ranges: 指定颜色组中的完整标记范围，合计至多十万项。
    /// - tree: 与标记身份相同的固定正文。
    /// - permit: 当前复制任务仍有效的取消权限。
    /// 返回：原文片段以 LF 分隔且合计不超过 64 MiB；空匹配、过期、取消或五秒预算失败不返回部分内容。
    static func prepare(
        _ ranges: [ByteRange],
        tree: PieceTree,
        permit: @Sendable () -> Bool
    ) throws -> (text: String, fragments: Int, empty: Int) {
        guard ranges.count <= 100_000 else {
            throw NateError.message("复制标记文本超过十万项，剪贴板保留。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var unique: Set<ByteRange> = []
        var empty = 0
        for range in ranges {
            try checkpoint(permit, deadline: deadline)
            // 标记必须属于原快照的完整字符边界，不能把错误偏移夹断到相邻正文。
            guard range.lower >= 0, range.upper >= range.lower,
                tree.isBoundary(range.lower), tree.isBoundary(range.upper)
            else {
                throw NateError.invalidRange
            }
            if range.isEmpty {
                empty += 1
            }
            else {
                unique.insert(range)
            }
        }
        var comparisons = 0
        let ordered = try unique.sorted {
            left,
            right in
            comparisons += 1
            if comparisons & 1023 == 0 {
                try checkpoint(permit, deadline: deadline)
            }
            return left.lower == right.lower ? left.upper < right.upper : left.lower < right.lower
        }
        var merged: [ByteRange] = []
        for range in ordered {
            if let last = merged.last, range.lower < last.upper {
                merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
            }
            else {
                merged.append(range)
            }
        }
        guard !merged.isEmpty else {
            throw NateError.message(empty > 0 ? "标记均为空匹配，没有可复制正文；剪贴板保留。" : "当前没有可复制的标记文本。")
        }
        var remaining = 64 * 1024 * 1024
        var output = ""
        for range in merged {
            try checkpoint(permit, deadline: deadline)
            guard range.count < remaining else {
                throw NateError.message("复制标记文本超过 64 MiB，剪贴板保留。")
            }
            remaining -= range.count + 1
            var offset = range.lower
            while offset < range.upper {
                try checkpoint(permit, deadline: deadline)
                var end = min(range.upper, offset + 65_536)
                while end > offset && !tree.isBoundary(end) {
                    end -= 1
                }
                output += tree.text(in: ByteRange(offset, end))
                offset = end
            }
            output += "\n"
        }
        try checkpoint(permit, deadline: deadline)
        return (output, merged.count, empty)
    }

    /// 业务作用：范围验证、排序和正文分块读取共享取消与截止，旧复制不能继续占用后台计算。
    /// 参数说明:
    /// - permit: 本次复制仍然拥有的执行资格。
    /// - deadline: 整份复制共用的截止时刻。
    /// 返回：仍有资格与时间时继续，否则整体失败。
    private static func checkpoint(
        _ permit: @Sendable () -> Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("复制标记文本超过五秒，剪贴板保留。")
        }
    }
}
