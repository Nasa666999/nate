import Foundation

struct ChangeHistoryAction: Sendable {
    let position: Int
    let count: Int
    let insertion: Bool
}

struct ChangeHistoryGroup: Sendable {
    let id: UUID
    let actions: [ChangeHistoryAction]
}

enum ChangeHistoryEvent: Sendable {
    case edit(ChangeHistoryGroup)
    case undo(UUID)
    case redo(UUID)
}

struct ChangeHistoryLedger: Sendable {
    private(set) var state: ChangeHistoryState
    private(set) var groups: [ChangeHistoryGroup] = []
    private(set) var current = 0
    private(set) var savePoint = 0
    private(set) var detach: Int?
    private var retainedActions = 0

    /// 业务作用：正文事务共享一套修改历史，复合替换的删除和插入不能产生多个保存边界。
    /// 参数说明:
    /// - length: 初始正文的原字节长度。
    /// 返回：原生类别状态与空事务时间线同时建立。
    init(length: Int) throws {
        state = try ChangeHistoryState(length: length)
    }

    /// 业务作用：准备同一快照上的全部替换，按逆文档顺序还原真实删除与插入的执行坐标。
    /// 参数说明:
    /// - id: 正文撤销项的稳定身份。
    /// - changes: 同一来源上的有序非交叠字节修改。
    /// - deadline: 本次整份准备的共同截止。
    /// - permit: 来源仍有效且允许继续准备。
    /// 返回：完整事务动作；取消、超量、交叠或非法范围时不提供部分事务。
    static func group(
        id: UUID,
        changes: [PositionChange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> ChangeHistoryGroup {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("修改历史事务已经失去来源或超过截止，未开始准备。")
        }
        guard changes.count <= 500_000 else {
            throw NateError.message("修改历史单次替换超过五十万项，未采用部分事务。")
        }
        var actions: [ChangeHistoryAction] = []
        actions.reserveCapacity(changes.count * 2)
        var previous = Int.max
        for (index, change) in changes.reversed().enumerated() {
            if index & 255 == 0 {
                try Task.checkCancellation()
                guard permit(), ContinuousClock.now < deadline else {
                    throw NateError.message("修改历史事务来源失效或超过截止，未采用部分事务。")
                }
            }
            guard change.range.lower >= 0, change.range.upper >= change.range.lower,
                change.range.upper <= previous, change.insertedByteCount >= 0
            else {
                throw NateError.message("修改历史事务包含非法或交叠范围，未采用部分事务。")
            }
            previous = change.range.lower
            if !change.range.isEmpty {
                actions.append(
                    ChangeHistoryAction(
                        position: change.range.lower,
                        count: change.range.count,
                        insertion: false
                    )
                )
            }
            if change.insertedByteCount > 0 {
                actions.append(
                    ChangeHistoryAction(
                        position: change.range.lower,
                        count: change.insertedByteCount,
                        insertion: true
                    )
                )
            }
        }
        return ChangeHistoryGroup(id: id, actions: actions)
    }

    /// 业务作用：整个正文事务、撤销或重做先完成候选，原生修改类别不能在复合事务中半发布。
    /// 参数说明:
    /// - event: 对应同一正文历史项的完整事件。
    /// - deadline: 所有内部字节操作共同的截止。
    /// - permit: 当前来源及操作资格。
    /// 返回：完整迁移成功时替换时间线，失败保留原状态和历史位置。
    mutating func apply(
        _ event: ChangeHistoryEvent,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("修改历史事件已经失去来源或超过截止，未开始迁移。")
        }
        var candidate = self
        switch event {
        case .edit(let group):
            if candidate.current < candidate.savePoint {
                candidate.savePoint = -1
                if candidate.detach == nil {
                    candidate.detach = candidate.current
                }
            }
            else if let detach = candidate.detach, detach > candidate.current {
                candidate.detach = candidate.current
            }
            for group in candidate.groups[candidate.current...] {
                candidate.retainedActions -= group.actions.count
            }
            candidate.groups.removeSubrange(candidate.current...)
            guard candidate.groups.count < 65_536,
                group.actions.count <= 1_000_000 - candidate.retainedActions
            else {
                throw NateError.message("修改历史事务超过 65536 项或一百万个原字节动作，未采用部分记录。")
            }
            try candidate.perform(
                group,
                backwards: false,
                appending: true,
                deadline: deadline,
                permit: permit
            )
            candidate.groups.append(group)
            candidate.retainedActions += group.actions.count
            candidate.current += 1
        case .undo(let id):
            guard candidate.current > 0, candidate.groups[candidate.current - 1].id == id else {
                throw NateError.message("修改历史撤销身份已经改变，未采用另一事务的记录。")
            }
            try candidate.perform(
                candidate.groups[candidate.current - 1],
                backwards: true,
                appending: false,
                deadline: deadline,
                permit: permit
            )
            candidate.current -= 1
        case .redo(let id):
            guard candidate.current < candidate.groups.count, candidate.groups[candidate.current].id == id
            else {
                throw NateError.message("修改历史重做身份已经改变，未采用另一事务的记录。")
            }
            try candidate.perform(
                candidate.groups[candidate.current],
                backwards: false,
                appending: false,
                deadline: deadline,
                permit: permit
            )
            candidate.current += 1
        }
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("修改历史事务失去来源或超过截止，未发布候选。")
        }
        self = candidate
    }

    /// 业务作用：正文已经释放的撤销前缀不再占用事务索引，现有修改证据和可用重做继续保留。
    /// 参数说明:
    /// - count: 正文内核仍能撤销的完整事务数量。
    /// 返回：只移除无法再撤销的事务前缀，保存与分支边界同步平移。
    mutating func retainUndoCount(_ count: Int) {
        let removed = max(0, current - max(0, count))
        guard removed > 0 else {
            return
        }
        for group in groups.prefix(removed) {
            retainedActions -= group.actions.count
        }
        groups.removeFirst(removed)
        current -= removed
        if savePoint >= 0 {
            savePoint = max(0, savePoint - removed)
        }
        if let detach {
            self.detach = max(0, detach - removed)
        }
    }

    /// 业务作用：成功写盘的固定正文建立保存边界，打开后已保存的修改仍保留原生标记。
    /// 参数说明:
    /// - deadline: 完整保存类别转换的共同截止。
    /// - permit: 该固定保存结果仍可发布。
    /// 返回：类别与保存点同时推进，失败保留原来的完整时间线。
    mutating func save(
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try state.apply(.save, deadline: deadline, permit: permit)
        savePoint = current
        detach = nil
    }

    /// 业务作用：复合事务中的每个原字节动作沿同一保存与分支关系执行，重做不能丢失此前撤销覆盖。
    /// 参数说明:
    /// - group: 正文历史项的完整有序动作。
    /// - backwards: 为真时按反向顺序撤销。
    /// - appending: 为真时动作来自新的正文事务，否则来自重做。
    /// - deadline: 本事务全部动作的共同截止。
    /// - permit: 当前操作资格。
    /// 返回：全部动作按真实历史顺序完成；任何失败由外层候选整体回收。
    private mutating func perform(
        _ group: ChangeHistoryGroup,
        backwards: Bool,
        appending: Bool,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws {
        if backwards, savePoint < 0 || savePoint >= current {
            try state.apply(.startReversion, deadline: deadline, permit: permit)
        }
        for index in group.actions.indices {
            let action = group.actions[backwards ? group.actions.count - 1 - index : index]
            let mutation: ChangeHistoryMutation
            if backwards {
                let before = savePoint < 0 || savePoint >= current
                let detached =
                    detach.map {
                        $0 < current
                    } ?? false
                mutation =
                    action.insertion
                    ? .undoInsertion(
                        position: action.position,
                        count: action.count,
                        reverting: before && !detached
                    )
                    : .undoDeletion(position: action.position, count: action.count, detached: detached)
            }
            else {
                let reachable = savePoint > 0 && savePoint > current
                let detached =
                    detach.map {
                        $0 <= current
                    } ?? false
                let before = appending ? reachable : (savePoint < 0 || savePoint > current) && !detached
                mutation =
                    action.insertion
                    ? .insert(position: action.position, count: action.count, beforeSave: before)
                    : .delete(
                        position: action.position,
                        count: action.count,
                        beforeSave: reachable,
                        detached: detached
                    )
            }
            try state.apply(mutation, deadline: deadline, permit: permit)
            if !backwards, !appending, savePoint >= 0, savePoint <= current {
                try state.apply(.endReversion, deadline: deadline, permit: permit)
            }
        }
    }
}
