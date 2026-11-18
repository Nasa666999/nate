import Foundation
import NateCore

enum MarkedTextExport {
    /// 业务作用：按颜色指示区复制完整原文，同色连续覆盖归并，不同颜色的重叠分别保留。
    /// 参数说明:
    /// - groups: 用户选择的至多六个颜色组，各组保留独立范围身份，合计至多十万项。
    /// - tree: 与标记身份相同的固定正文。
    /// - permit: 当前复制任务仍有效的取消权限。
    /// 返回：按原位置排序的片段；单片段不补换行，多片段以 CRLF 或跨行分隔线连接并补末尾 CRLF，合计至多 64 MiB；空标记、取消或五秒超限整体失败。
    static func prepare(
        _ groups: [[ByteRange]],
        tree: PieceTree,
        permit: @Sendable () -> Bool
    ) throws -> (text: String, fragments: Int, empty: Int) {
        guard groups.count <= DocumentMarkStyle.allCases.count else {
            throw NateError.message("复制标记文本最多使用六个颜色组，剪贴板保留。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var available = 100_000
        var empty = 0
        var fragments: [ByteRange] = []
        for group in groups {
            guard group.count <= available else {
                throw NateError.message("复制标记文本超过十万项，剪贴板保留。")
            }
            available -= group.count
            var nonempty: [ByteRange] = []
            for range in group {
                try checkpoint(permit, deadline: deadline)
                // 颜色范围必须属于原快照的完整标量，不能把非法偏移夹断为邻近正文。
                guard range.lower >= 0, range.upper >= range.lower,
                    tree.isBoundary(range.lower), tree.isBoundary(range.upper)
                else {
                    throw NateError.invalidRange
                }
                if range.isEmpty {
                    empty += 1
                }
                else {
                    nonempty.append(range)
                }
            }
            let ordered = try sorted(nonempty, permit: permit, deadline: deadline)
            var merged: [ByteRange] = []
            for range in ordered {
                try checkpoint(permit, deadline: deadline)
                if let last = merged.last, range.lower <= last.upper {
                    merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
                }
                else {
                    merged.append(range)
                }
            }
            fragments.append(contentsOf: merged)
        }
        guard !fragments.isEmpty else {
            throw NateError.message(empty > 0 ? "标记均为空匹配，没有可复制正文；剪贴板保留。" : "当前没有可复制的标记文本。")
        }
        // 跨颜色的覆盖是独立指示区，不能在全局排序时再次合并或去重。
        let ordered = try sorted(fragments, permit: permit, deadline: deadline)
        let capacity = 64 * 1024 * 1024
        var sourceBytes = 0
        for range in ordered {
            guard range.count <= capacity - sourceBytes else {
                throw NateError.message("复制标记文本超过 64 MiB，剪贴板保留。")
            }
            sourceBytes += range.count
        }
        var multiline = false
        if ordered.count > 1 {
            for range in ordered {
                var position = range.lower
                while position < range.upper && !multiline {
                    try checkpoint(permit, deadline: deadline)
                    let end = min(range.upper, position + 65_536)
                    multiline = tree.bytes(in: ByteRange(position, end)).contains {
                        $0 == 13 || $0 == 10
                    }
                    position = end
                }
                if multiline {
                    break
                }
            }
        }
        let delimiter = multiline ? "\r\n----\r\n" : "\r\n"
        let overhead = (ordered.count - 1) * delimiter.utf8.count + (ordered.count > 1 ? 2 : 0)
        guard sourceBytes <= capacity - overhead else {
            throw NateError.message("复制标记文本及分隔符超过 64 MiB，剪贴板保留。")
        }
        var output = ""
        output.reserveCapacity(sourceBytes + overhead)
        for (index, range) in ordered.enumerated() {
            if index > 0 {
                output += delimiter
            }
            var position = range.lower
            while position < range.upper {
                try checkpoint(permit, deadline: deadline)
                var end = min(range.upper, position + 65_536)
                while !tree.isBoundary(end) {
                    end -= 1
                }
                output += tree.text(in: ByteRange(position, end))
                position = end
            }
        }
        if ordered.count > 1 {
            output += "\r\n"
        }
        try checkpoint(permit, deadline: deadline)
        return (output, ordered.count, empty)
    }

    /// 业务作用：按原始起点排序各颜色片段，同起点的短前缀先输出，不使用规范等价字符串比较。
    /// 参数说明:
    /// - ranges: 已校验的实际源范围。
    /// - permit: 本次复制的取消权限。
    /// - deadline: 整份复制共用的截止时刻。
    /// 返回：有序完整范围，排序期间失权或超时整体失败。
    private static func sorted(
        _ ranges: [ByteRange],
        permit: @Sendable () -> Bool,
        deadline: ContinuousClock.Instant
    ) throws -> [ByteRange] {
        var comparisons = 0
        return try ranges.sorted {
            left,
            right in
            comparisons += 1
            if comparisons & 1023 == 0 {
                try checkpoint(permit, deadline: deadline)
            }
            return left.lower == right.lower ? left.upper < right.upper : left.lower < right.lower
        }
    }

    /// 业务作用：验证、排序、换行检测和正文分块读取共享取消与截止，旧复制不能继续占用后台计算。
    /// 参数说明:
    /// - permit: 本次复制仍然拥有的执行资格。
    /// - deadline: 整份复制共用的截止时刻。
    /// 返回：仍有资格与时间时继续，否则整体失败。
    private static func checkpoint(
        _ permit: @Sendable () -> Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("复制标记文本超过五秒，剪贴板保留。")
        }
    }
}
