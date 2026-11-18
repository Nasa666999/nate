import Foundation

extension DocumentMarkState {
    /// 业务作用：颜色按原文片段随行重排，跨行范围只合并自身重新相邻的片段，用户后来清除的样式不从历史恢复。
    /// 参数说明:
    /// - permutation: 已完整校验的本次行移动索引。
    /// - text: 重排后完整正文，用于复验所有结果字节边界。
    /// - deadline: 外层动作的共享截止，本次颜色映射最多再使用两秒。
    /// - permit: 当前仍可继续准备元数据的执行资格。
    /// 返回：完整移动后的颜色状态；超过十万结果、二百万处理步、时间或权限时整体失败。
    public func relocated(
        by permutation: TextPermutation,
        in text: PieceTree,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DocumentMarkState {
        guard permutation.scope.upper <= text.byteCount else {
            throw NateError.invalidRange
        }
        let ownDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        let deadline = min(deadline ?? ownDeadline, ownDeadline)
        var work = 0, total = 0
        var result = DocumentMarkState()
        for style in DocumentMarkStyle.allCases {
            var distinct: Set<ByteRange> = []
            for range in ranges(for: style) {
                try Self.relocationCheckpoint(&work, deadline: deadline, permit: permit)
                if range.isEmpty {
                    let position = permutation.map(range.lower)
                    guard text.isBoundary(position) else {
                        throw NateError.invalidRange
                    }
                    distinct.insert(ByteRange(position, position))
                }
                else {
                    let pieces = try Self.relocationPieces(
                        range,
                        permutation: permutation,
                        work: &work,
                        deadline: deadline,
                        permit: permit
                    )
                    for piece in pieces {
                        guard text.isBoundary(piece.lower), text.isBoundary(piece.upper) else {
                            throw NateError.invalidRange
                        }
                        distinct.insert(piece)
                    }
                }
                guard distinct.count <= 100_000 - total else {
                    throw NateError.message("行重排后的颜色片段超过十万项，原正文与标记保持不变。")
                }
            }
            let ordered = try distinct.sorted {
                left,
                right in
                try Self.relocationCheckpoint(&work, deadline: deadline, permit: permit)
                return left.lower == right.lower ? left.upper < right.upper : left.lower < right.lower
            }
            if !ordered.isEmpty {
                result.groups[style] = DocumentMarkIndex(ranges: ordered)
                total += ordered.count
            }
        }
        try Self.relocationCheckpoint(&work, deadline: deadline, permit: permit, force: true)
        return result
    }

    /// 业务作用：一个原颜色范围按源行分解后移动，区间之外保留原位，不把两个端点之间的无关新行一并着色。
    /// 参数说明:
    /// - range: 原文中的一个非空颜色范围。
    /// - permutation: 本次完整移动关系。
    /// - work: 整份颜色状态共享的工作量。
    /// - deadline: 整份映射的固定截止。
    /// - permit: 当前执行资格。
    /// 返回：该原范围在新正文中的全部连续片段，相邻片段重新合并但不吞并其它原始匹配。
    private static func relocationPieces(
        _ range: ByteRange,
        permutation: TextPermutation,
        work: inout Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange] {
        let scope = permutation.scope
        var pieces: [ByteRange] = []
        if range.lower < scope.lower {
            pieces.append(ByteRange(range.lower, min(range.upper, scope.lower)))
        }
        let segments = permutation.forward
        var lower = 0, upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].source.upper <= range.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        for segment in segments.dropFirst(lower) {
            if segment.source.lower >= range.upper {
                break
            }
            try relocationCheckpoint(&work, deadline: deadline, permit: permit)
            let first = max(range.lower, segment.source.lower)
            let last = min(range.upper, segment.source.upper)
            guard first < last else {
                continue
            }
            let a = segment.destination.lower + min(first - segment.source.lower, segment.destination.count)
            // 原结束符的完整终点对应目标完整终点，CRLF 与 LF 之间的转换不留下半个颜色结束符。
            let b =
                last == segment.source.upper
                ? segment.destination.upper
                : segment.destination.lower + min(last - segment.source.lower, segment.destination.count)
            if a < b {
                pieces.append(ByteRange(a, b))
            }
        }
        if range.upper > scope.upper {
            pieces.append(ByteRange(max(range.lower, scope.upper), range.upper))
        }
        let ordered = try pieces.sorted {
            left,
            right in
            try relocationCheckpoint(&work, deadline: deadline, permit: permit)
            return left.lower == right.lower ? left.upper < right.upper : left.lower < right.lower
        }
        var merged: [ByteRange] = []
        for piece in ordered {
            if let last = merged.last, piece.lower <= last.upper {
                merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, piece.upper))
            }
            else {
                merged.append(piece)
            }
        }
        return merged
    }

    /// 业务作用：片段读取与排序共用权限和时间，复杂跨行颜色不能绕过整批元数据的处理上限。
    /// 参数说明:
    /// - work: 本轮所有片段和比较的累计工作量。
    /// - deadline: 固定单调截止。
    /// - permit: 调用方仍持有的准备资格。
    /// - force: 是否立即复验而不等待下一个周期检查。
    /// 返回：仍在二百万步、两秒和有效权限内则继续，否则不交回部分颜色状态。
    private static func relocationCheckpoint(
        _ work: inout Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool,
        force: Bool = false
    ) throws {
        work += 1
        guard work <= 2_000_000 else {
            throw NateError.message("行重排的颜色映射超过二百万步，原正文与标记保持不变。")
        }
        if force || work & 1023 == 1 {
            try Task.checkCancellation()
            guard permit() else {
                throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
                throw NateError.message("行重排的颜色映射超过两秒，原正文与标记保持不变。")
            }
        }
    }
}
