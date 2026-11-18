import Foundation

public struct DocumentMarkSnapshot: Sendable {
    public let document: DocumentSnapshot
    public let generation: UUID
    public let marks: DocumentMarkState

    /// 业务作用：文档正文与标记快照在同一执行域固定，后台标记计划同时绑定两类用户状态。
    /// 参数说明:
    /// - document: 当前真实正文修订。
    /// - generation: 当前颜色标记身份。
    /// - marks: 当前独立颜色集合。
    /// 返回：可后台使用的不可变输入，只在本次计划期间结构共享正文。
    init(document: DocumentSnapshot, generation: UUID, marks: DocumentMarkState) {
        self.document = document
        self.generation = generation
        self.marks = marks
    }
}

public struct PreparedDocumentMarks: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let generation: UUID
    public let style: DocumentMarkStyle
    public let count: Int
    let state: DocumentMarkState

    /// 业务作用：后台完整验证和构建颜色标记，保留旧组或替换当前组都在发布前确定容量与字符边界。
    /// 参数说明:
    /// - snapshot: 同时固定正文与标记身份的输入。
    /// - ranges: 本次实际匹配范围，包含可无损表示的零长度匹配。
    /// - style: 本次更新的独立颜色组。
    /// - append: 是否保留该组的旧标记，其它组始终保留。
    /// - permit: 当前后台计划仍拥有的取消权限。
    /// 返回：至多十万项、共用两秒构建预算的完整计划，取消、越界或超限不产生可发布部分状态。
    public init(
        snapshot: DocumentMarkSnapshot,
        ranges: [ByteRange],
        style: DocumentMarkStyle,
        append: Bool,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard ranges.count <= 100_000 else {
            throw NateError.message("一次最多设置十万个颜色标记，已有标记保留。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var state = snapshot.marks
        let others = state.count - (state.groups[style]?.ranges.count ?? 0)
        var unique = Set(append ? state.ranges(for: style) : [])
        for range in ranges {
            try Self.checkpoint(permit, deadline: deadline)
            // 非字符边界或倒置范围不能变成近邻字符高亮，必须在整份标记发布前拒绝。
            guard range.lower >= 0, range.upper >= range.lower,
                snapshot.document.text.isBoundary(range.lower), snapshot.document.text.isBoundary(range.upper)
            else {
                throw NateError.invalidRange
            }
            unique.insert(range)
            guard unique.count <= 100_000 - others else {
                throw NateError.message("查找与五组样式合计最多十万个标记，已有标记保留。")
            }
        }
        var comparisons = 0
        let ordered = try unique.sorted {
            left,
            right in
            comparisons += 1
            if comparisons & 1023 == 0 {
                try Self.checkpoint(permit, deadline: deadline)
            }
            return left.lower == right.lower ? left.upper < right.upper : left.lower < right.lower
        }
        if ordered.isEmpty {
            state.groups.removeValue(forKey: style)
        }
        else {
            state.groups[style] = DocumentMarkIndex(ranges: ordered)
        }
        try Self.checkpoint(permit, deadline: deadline)
        documentID = snapshot.document.id
        revision = snapshot.document.revision
        generation = snapshot.generation
        self.style = style
        count = ordered.count
        self.state = state
    }

    /// 业务作用：范围校验、去重和排序共用实际取消与截止，旧计划不能继续占用标记构建资源。
    /// 参数说明:
    /// - permit: 调用者仍持有的本次执行资格。
    /// - deadline: 整份计划共用的截止时刻。
    /// 返回：仍有资格与时间时继续，否则整体终止。
    private static func checkpoint(
        _ permit: @Sendable () -> Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("颜色标记构建超过两秒，已有标记保留。")
        }
    }
}
