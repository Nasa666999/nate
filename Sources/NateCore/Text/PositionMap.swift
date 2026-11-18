import Foundation

private struct MappedChange: Sendable {
    let lower: Int
    let upper: Int
    let resultEnd: Int
    let resultStart: Int
    let deltaAfter: Int
}

public struct PositionMap: Sendable {
    private let entries: [MappedChange]
    let permutation: TextPermutation?
    var changeCount: Int {
        permutation?.indexedCount ?? entries.count
    }
    var retainedBytes: Int {
        entries.count * MemoryLayout<MappedChange>.stride + (permutation?.retainedBytes ?? 0)
    }

    /// 业务作用：无正文变化时保留全部位置，格式事务也可记录同一修订链。
    /// 参数说明: 无。
    /// 返回：恒等映射。
    public init() {
        entries = []
        permutation = nil
    }

    /// 业务作用：行重排采用真实片段位置，不能把整个排序区间中的光标统一收拢到末尾。
    /// 参数说明:
    /// - permutation: 已验证完整覆盖的双向移动索引。
    /// 返回：区间外恒等、区间内随原文移动的位置映射；恒等重排不保留多余索引。
    public init(permutation: TextPermutation) {
        entries = []
        self.permutation = permutation.isIdentity ? nil : permutation
    }

    /// 业务作用：为原子修改建立二分位置索引，避免多光标与书签逐项扫描全部编辑。
    /// 参数说明:
    /// - edits: 同一修改前快照上的非交叠编辑。
    /// 返回：合法映射；负范围、交叠或位置溢出时拒绝。
    public init(edits: [TextEdit]) throws {
        let ordered = edits.sorted {
            $0.range.lower == $1.range.lower
                ? $0.range.upper < $1.range.upper : $0.range.lower < $1.range.lower
        }
        var previous: ByteRange?
        var delta = 0
        for edit in ordered {
            guard edit.range.lower >= 0, edit.range.upper >= edit.range.lower else {
                throw NateError.invalidRange
            }
            if let previous {
                guard previous.upper <= edit.range.lower, !(previous.isEmpty && previous == edit.range) else {
                    throw NateError.overlappingEdits
                }
            }
            let start = edit.range.lower.addingReportingOverflow(delta)
            let end = start.partialValue.addingReportingOverflow(edit.text.utf8.count)
            let next = delta.addingReportingOverflow(edit.text.utf8.count - edit.range.count)
            guard !start.overflow, !end.overflow, !next.overflow else {
                throw NateError.invalidRange
            }
            delta = next.partialValue
            previous = edit.range
        }
        self.init(
            validatedChanges: ordered.map {
                PositionChange(range: $0.range, insertedByteCount: $0.text.utf8.count)
            }
        )
    }

    /// 业务作用：已校验事务及其反向变化共享同一索引，保留重合端点的原始优先级。
    /// 参数说明:
    /// - validatedChanges: 非交叠事务或已完成构造的反向位置变化。
    /// 返回：可在快照与历史之间共享的不可变索引。
    init(validatedChanges: [PositionChange]) {
        permutation = nil
        var delta = 0
        entries = validatedChanges.map {
            change in
            let result = change.range.lower + delta + change.insertedByteCount
            delta += change.insertedByteCount - change.range.count
            return MappedChange(
                lower: change.range.lower,
                upper: change.range.upper,
                resultEnd: result,
                resultStart: result - change.insertedByteCount,
                deltaAfter: delta
            )
        }
    }

    /// 业务作用：普通替换内部位置收拢到末端，行重排中的位置跟随原片段与后侧边界。
    /// 参数说明:
    /// - position: 修改前的合法位置。
    /// 返回：修改后的字节位置，不重新解释 Unicode 或隐式夹断范围。
    public func map(_ position: Int) -> Int {
        if let permutation {
            return permutation.map(position)
        }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].upper < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < entries.count else {
            return position + (entries.last?.deltaAfter ?? 0)
        }
        let entry = entries[lower]
        if position < entry.lower {
            return position + (lower > 0 ? entries[lower - 1].deltaAfter : 0)
        }
        return entry.resultEnd
    }

    /// 业务作用：范围锚点明确归属于边界前侧或后侧，边界插入不会无意扩张相邻颜色标记。
    /// 参数说明:
    /// - position: 修改前快照中的合法字节位置。
    /// - affinity: 同点插入和被替换位置归属前侧或后侧。
    /// 返回：当前事务后的合法位置；后侧跨过同点后续修改，前侧保留替换结束边界。
    public func map(_ position: Int, affinity: PositionAffinity) -> Int {
        if let permutation {
            return permutation.map(position, affinity: affinity)
        }
        var lower = 0
        var upper = entries.count
        if affinity == .after {
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if entries[middle].lower <= position {
                    lower = middle + 1
                }
                else {
                    upper = middle
                }
            }
            guard lower > 0 else {
                return position
            }
            let entry = entries[lower - 1]
            return position <= entry.upper ? entry.resultEnd : position + entry.deltaAfter
        }
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].upper < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < entries.count else {
            return position + (entries.last?.deltaAfter ?? 0)
        }
        let entry = entries[lower]
        if position < entry.lower {
            return position + (lower > 0 ? entries[lower - 1].deltaAfter : 0)
        }
        return position == entry.upper && entry.lower < entry.upper ? entry.resultEnd : entry.resultStart
    }
}

public enum PositionAffinity: Sendable {
    case before
    case after
}
