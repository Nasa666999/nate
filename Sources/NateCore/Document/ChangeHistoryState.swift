import Foundation

enum ChangeHistoryMutation: Sendable {
    case insert(position: Int, count: Int, beforeSave: Bool)
    case delete(position: Int, count: Int, beforeSave: Bool, detached: Bool)
    case undoInsertion(position: Int, count: Int, reverting: Bool)
    case undoDeletion(position: Int, count: Int, detached: Bool)
    case startReversion
    case endReversion
    case save
}

struct ChangeHistoryState: Sendable {
    private(set) var log: ChangeHistoryLog
    private(set) var reversions: ChangeHistoryLog?

    /// 业务作用：原文和撤销覆盖分别维护完整修改证据，保存不会清除打开后发生的修改位置。
    /// 参数说明:
    /// - length: 初始正文的原字节长度。
    /// 返回：合法长度对应的原始状态；非法长度整体拒绝。
    init(length: Int) throws {
        guard (0...Int.max / 2).contains(length) else {
            throw NateError.message("修改历史的初始正文长度无效。")
        }
        log = ChangeHistoryLog(length: length)
    }

    /// 业务作用：显示状态与正文事务使用同一字节长度，文件末尾删除可独立保留锚点。
    /// 参数说明: 无。
    /// 返回：当前历史所对应正文的原字节长度。
    var length: Int {
        log.runs.length
    }

    /// 业务作用：每项历史状态迁移先在独立候选完成，失败不留下半份插入、删除或撤销覆盖。
    /// 参数说明:
    /// - mutation: 与已经确认的正文操作对应的完整迁移。
    /// - deadline: 整份候选共用的计算截止。
    /// - permit: 候选所属来源和操作仍有执行资格。
    /// 返回：完整合法候选一次发布；取消、无效范围或容量不足时保留原状态。
    mutating func apply(
        _ mutation: ChangeHistoryMutation,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let work = ChangeHistoryWork(deadline: deadline, permit: permit)
        try work.check()
        var candidate = self
        candidate.configureWork(work)
        try candidate.perform(mutation)
        try candidate.log.validateCapacity()
        try candidate.reversions?.validateCapacity()
        guard candidate.reversions == nil || candidate.reversions?.runs.length == candidate.length else {
            throw NateError.message("修改历史与撤销覆盖的正文长度不一致，未采用部分记录。")
        }
        try work.check()
        // 发布的历史不保留本次调用者的来源闭包或过期截止，后续迁移必须取得自己的完整执行证据。
        candidate.configureWork(ChangeHistoryWork())
        self = candidate
    }

    /// 业务作用：文字状态同时考虑原修改与跨保存点的撤销，已保存修改不会被解释成未改动原文。
    /// 参数说明:
    /// - position: 当前正文中的原字节位置，允许末尾。
    /// 返回：零为原始正文，一为撤回原始，二为已保存，三为未保存，四为撤回已修改。
    func edition(at position: Int) -> Int {
        let value = log.runs.value(at: position)
        if let reversion = reversions?.runs.value(at: position), reversion != 0 {
            return value > 0 ? 4 : 1
        }
        return value
    }

    /// 业务作用：绘制按两个完整日志的共同区间边界推进，不能越过更短的撤销覆盖。
    /// 参数说明:
    /// - position: 当前正文中的扫描位置。
    /// 返回：原修改和撤销覆盖中最早的区间末端。
    func endRun(at position: Int) -> Int {
        min(log.runs.end(at: position), reversions?.runs.end(at: position) ?? length)
    }

    /// 业务作用：删除锚点可同时保留多类历史，撤销覆盖按该点是否已有修改区分原始与修改回退。
    /// 参数说明:
    /// - position: 当前正文中的精确删除锚点。
    /// 返回：四类删除状态的完整位集合，不把多次删除压成单一布尔值。
    func deletionEditions(at position: Int) -> Int {
        var result = log.editions(at: position).reduce(0) {
            $0 | (1 << ($1.edition - 1))
        }
        if let reversions, !reversions.editions(at: position).isEmpty {
            result |= result & 6 == 0 ? 1 : 8
        }
        return result
    }

    /// 业务作用：稀疏删除遍历直接跳到下一实际锚点，末尾哨兵保证空文件遍历能够结束。
    /// 参数说明:
    /// - position: 本次已经检查的原字节位置。
    /// 返回：两个日志中最早的后继删除位置，末尾之后为长度加一。
    func nextDeletion(after position: Int) -> Int {
        let first = log.deletionIndex(at: position + 1)
        var next = first < log.deletions.count ? log.deletions[first].position : length + 1
        if let reversions {
            let index = reversions.deletionIndex(at: position + 1)
            if index < reversions.deletions.count {
                next = min(next, reversions.deletions[index].position)
            }
        }
        return next
    }

    /// 业务作用：按原生历史顺序迁移插入、删除、保存与撤销覆盖，来源失败由外层候选整体回收。
    /// 参数说明:
    /// - mutation: 当前唯一完整迁移。
    /// 返回：候选完成对应状态变化，范围或逆向证据不足时拒绝。
    private mutating func perform(_ mutation: ChangeHistoryMutation) throws {
        switch mutation {
        case .startReversion:
            if reversions == nil {
                reversions = ChangeHistoryLog(length: length)
                configureWork(log.work)
            }
        case .endReversion:
            reversions = nil
        case .save:
            try log.save()
            reversions = nil
        case .insert(let position, let count, let beforeSave):
            try validate(position: position, count: count, deleting: false)
            try log.insertSpace(at: position, count: count)
            try log.runs.fill(at: position, count: count, edition: beforeSave ? 2 : 3)
            if reversions != nil {
                try reversions?.insertSpace(at: position, count: count)
                if beforeSave {
                    try reversions?.restoreDeletion(at: position, count: count)
                }
            }
        case .delete(let position, let count, let beforeSave, let detached):
            try validate(position: position, count: count, deleting: true)
            try log.saveHistory(at: position, count: count)
            try log.delete(at: position, count: count)
            log.pushDeletion(at: position, value: ChangeHistoryCount(edition: beforeSave ? 2 : 3, count: 1))
            if reversions != nil {
                if detached {
                    try reversions?.saveHistory(at: position, count: count)
                }
                try reversions?.delete(at: position, count: count)
            }
        case .undoInsertion(let position, let count, let reverting):
            try validate(position: position, count: count, deleting: true)
            try log.delete(at: position, count: count)
            if reversions != nil {
                try reversions?.saveHistory(at: position, count: count)
                try reversions?.delete(at: position, count: count)
                if reverting {
                    reversions?.pushDeletion(at: position, value: ChangeHistoryCount(edition: 1, count: 1))
                }
            }
        case .undoDeletion(let position, let count, let detached):
            try validate(position: position, count: count, deleting: false)
            try log.insertSpace(at: position, count: count)
            try log.restoreDeletion(at: position, count: count)
            if reversions != nil {
                try reversions?.insertSpace(at: position, count: count)
                if !detached {
                    try reversions?.runs.fill(at: position, count: count, edition: 1)
                }
            }
        }
    }

    /// 业务作用：当前候选的插入和删除及撤销覆盖使用相同执行窗口，发布前统一解除调用来源持有。
    /// 参数说明:
    /// - work: 当前调用的执行证据，空证据用于清除临时来源。
    /// 返回：全部内部索引采用同一证据，不改变任何修改类别或正文长度。
    private mutating func configureWork(_ work: ChangeHistoryWork) {
        log.work = work
        log.runs.work = work
        reversions?.work = work
        reversions?.runs.work = work
    }

    /// 业务作用：任何状态变化先确认完整字节范围，元数据不能延伸到另一份正文或溢出长度。
    /// 参数说明:
    /// - position: 当前正文中的动作起点。
    /// - count: 正数原字节长度。
    /// - deleting: 为真时原范围必须完整存在，否则校验新增后的长度。
    /// 返回：范围和长度可完整表示时通过，否则拒绝候选。
    private func validate(position: Int, count: Int, deleting: Bool) throws {
        guard position >= 0, position <= length, count > 0,
            deleting ? count <= length - position : count <= Int.max / 2 - length
        else {
            throw NateError.message("修改历史动作的完整字节范围无效，未采用部分记录。")
        }
    }
}
