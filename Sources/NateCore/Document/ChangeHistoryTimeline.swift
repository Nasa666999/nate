import Foundation

struct ChangeHistoryCheckpoint: Sendable {
    let epoch: UUID
    let sequence: UInt64
    let anchorSequence: UInt64
    let anchorLedger: ChangeHistoryLedger
    let confirmed: [UInt64]
    let prefix: [ChangeHistoryTimelineEvent]
}

struct ChangeHistoryTimelineEvent: Sendable {
    let sequence: UInt64
    let event: ChangeHistoryEvent
    let retainedActions: Int
}

struct ChangeHistoryReplayRequest: Sendable {
    let generation: UUID
    let sequence: UInt64
    let checkpoint: ChangeHistoryCheckpoint
    let events: [ChangeHistoryTimelineEvent]
    let undoCount: Int
    let groupIDs: [UUID]
    let length: Int
}

struct ChangeHistoryTimeline: Sendable {
    let epoch = UUID()
    private(set) var generation = UUID()
    private(set) var sequence: UInt64 = 0
    private(set) var ledger: ChangeHistoryLedger
    private(set) var events: [ChangeHistoryTimelineEvent] = []
    private var retainedActions = 0
    private var pending: ChangeHistoryCheckpoint?

    /// 业务作用：文档生命周期拥有独立事务时间线，后台保存只捕获自己的固定原文位置。
    /// 参数说明:
    /// - length: 新载入正文的原字节长度。
    /// 返回：原始正文、独立时间线身份及空的保存重放记录。
    init(length: Int) throws {
        ledger = try ChangeHistoryLedger(length: length)
    }

    /// 业务作用：记录已经确认的完整正文事务，保存等待期间的撤销与新分支也保持实际发生顺序。
    /// 参数说明:
    /// - event: 当前正文历史对应的完整事件。
    /// - undoCount: 正文内核仍保留的可撤销事务数量。
    /// - deadline: 本次完整历史迁移的共同截止。
    /// - permit: 当前来源仍有执行资格。
    /// 返回：事件、类别和来源代次一起发布；失败保留此前完整时间线。
    mutating func record(
        _ event: ChangeHistoryEvent,
        undoCount: Int,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard sequence < UInt64.max else {
            throw NateError.message("修改历史事务序号已经达到上限，未回绕到旧保存点。")
        }
        var candidate = self
        try candidate.ledger.apply(event, deadline: deadline, permit: permit)
        candidate.ledger.retainUndoCount(undoCount)
        candidate.sequence += 1
        let count: Int
        if case .edit(let group) = event {
            count = max(1, group.actions.count)
        }
        else {
            count = 1
        }
        candidate.events.append(
            ChangeHistoryTimelineEvent(sequence: candidate.sequence, event: event, retainedActions: count)
        )
        candidate.retainedActions += count
        while candidate.events.count > 4096 || candidate.retainedActions > 1_000_000 {
            candidate.retainedActions -= candidate.events.removeFirst().retainedActions
        }
        candidate.generation = UUID()
        self = candidate
    }

    /// 业务作用：原文件写入开始时固定实际修改历史，不把写入完成时的新正文冒用为这次保存内容。
    /// 参数说明: 无。
    /// 返回：固定原文位置及尚未发布的全部已确认保存事实；连续证据超量时拒绝捕获。
    func checkpoint() throws -> ChangeHistoryCheckpoint {
        if let pending {
            guard pending.confirmed.count < 4096 else {
                throw NateError.message("修改历史尚未发布的保存事实超过 4096 项，未丢弃旧保存点。")
            }
            return ChangeHistoryCheckpoint(
                epoch: epoch,
                sequence: sequence,
                anchorSequence: pending.anchorSequence,
                anchorLedger: pending.anchorLedger,
                confirmed: pending.confirmed,
                prefix: try completeEvents(prefix: pending.prefix, after: pending.sequence)
            )
        }
        return ChangeHistoryCheckpoint(
            epoch: epoch,
            sequence: sequence,
            anchorSequence: sequence,
            anchorLedger: ledger,
            confirmed: [],
            prefix: []
        )
    }

    /// 业务作用：后台保存类别重算只能使用从原写入快照开始的连续完整事务证据。
    /// 参数说明:
    /// - checkpoint: 实际已成功写盘正文在写入前捕获的位置。
    /// 返回：登记这次真实保存事实并固定完整重放；旧任务被取消也不会丢弃此前已经发生的保存。
    mutating func replayRequest(from checkpoint: ChangeHistoryCheckpoint) throws -> ChangeHistoryReplayRequest
    {
        guard checkpoint.epoch == epoch, checkpoint.sequence <= sequence,
            checkpoint.anchorSequence <= checkpoint.sequence,
            checkpoint.confirmed.last.map({
                $0 <= checkpoint.sequence
            }) != false,
            checkpoint.confirmed.count < 4096
        else {
            throw NateError.message("修改历史保存点不属于当前文档时间线，未采用旧来源。")
        }
        let complete = try completeEvents(prefix: checkpoint.prefix, after: checkpoint.sequence)
        let confirmed = ChangeHistoryCheckpoint(
            epoch: epoch,
            sequence: checkpoint.sequence,
            anchorSequence: checkpoint.anchorSequence,
            anchorLedger: checkpoint.anchorLedger,
            confirmed: checkpoint.confirmed + [checkpoint.sequence],
            prefix: checkpoint.prefix
        )
        // 后续写入可能在本次分类尚未发布时开始，捕获必须携带已经确认的整条保存事实链。
        pending = confirmed
        generation = UUID()
        return ChangeHistoryReplayRequest(
            generation: generation,
            sequence: sequence,
            checkpoint: confirmed,
            events: complete,
            undoCount: ledger.current,
            groupIDs: ledger.groups.map(\.id),
            length: ledger.state.length
        )
    }

    /// 业务作用：在固定写入正文上建立保存点后，按真实顺序重放期间修改，后续文字继续保持未保存类别。
    /// 参数说明:
    /// - request: 当前发布身份及从原保存点起的完整连续事件。
    /// - deadline: 保存分类与全部重放事件共同的截止。
    /// - permit: 该写盘结果仍属于当前路径、文档和操作。
    /// 返回：完整当前分类；取消、超量、缺链或历史不一致时不返回部分结果。
    static func prepareSaved(
        _ request: ChangeHistoryReplayRequest,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> ChangeHistoryLedger {
        var candidate = request.checkpoint.anchorLedger
        var expected = request.checkpoint.anchorSequence
        var point = 0
        let confirmed = request.checkpoint.confirmed
        while point < confirmed.count, confirmed[point] == expected {
            try candidate.save(deadline: deadline, permit: permit)
            point += 1
        }
        for entry in request.events {
            guard expected < UInt64.max, entry.sequence == expected + 1 else {
                throw NateError.message("修改历史保存重放缺少连续事务，未发布部分分类。")
            }
            try candidate.apply(entry.event, deadline: deadline, permit: permit)
            expected += 1
            while point < confirmed.count, confirmed[point] == expected {
                try candidate.save(deadline: deadline, permit: permit)
                point += 1
            }
        }
        candidate.retainUndoCount(request.undoCount)
        guard expected == request.sequence, point == confirmed.count,
            candidate.state.length == request.length,
            candidate.current == request.undoCount, candidate.groups.map(\.id) == request.groupIDs
        else {
            throw NateError.message("修改历史保存重放与当前正文历史不一致，未发布另一份分类。")
        }
        return candidate
    }

    /// 业务作用：后台重放完成后复验完整当前身份，输入或撤销期间迟到的旧分类没有发布权。
    /// 参数说明:
    /// - prepared: 已完成全部可失败计算的当前分类。
    /// - request: 本次准备时固定的来源与事务身份。
    /// 返回：身份保持时一次替换分类并推进发布代次；来源已变时原分类保持。
    mutating func publishSaved(_ prepared: ChangeHistoryLedger, for request: ChangeHistoryReplayRequest)
        -> Bool
    {
        guard generation == request.generation, sequence == request.sequence,
            epoch == request.checkpoint.epoch, prepared.state.length == ledger.state.length
        else {
            return false
        }
        ledger = prepared
        pending = nil
        generation = UUID()
        return true
    }

    /// 业务作用：捕获时已经保留的前缀与当前有界日志连接为同一连续序列，旧保存事实不能因任务替换丢失。
    /// 参数说明:
    /// - prefix: 从固定分类锚点到上次捕获位置的完整已保留事件。
    /// - previous: 该前缀对应的最后一个事务序号。
    /// 返回：到当前正文的完整事件；缺链或超过 4096 笔及一百万个动作时拒绝整份结果。
    private func completeEvents(prefix: [ChangeHistoryTimelineEvent], after previous: UInt64) throws
        -> [ChangeHistoryTimelineEvent]
    {
        let following = events.filter {
            $0.sequence > previous
        }
        guard previous <= sequence else {
            throw NateError.message("修改历史保存前缀不属于当前正文。")
        }
        if previous < sequence {
            guard following.first?.sequence == previous + 1, following.last?.sequence == sequence else {
                throw NateError.message("修改历史保存等待超过连续事务预算，未猜测已保存范围。")
            }
        }
        guard prefix.count <= 4096 - following.count else {
            throw NateError.message("修改历史保存事实链超过 4096 笔连续事务，未丢弃旧保存事实。")
        }
        let complete = prefix + following
        guard
            complete.reduce(
                0,
                {
                    $0 + $1.retainedActions
                }
            ) <= 1_000_000
        else {
            throw NateError.message("修改历史保存事实链超过一百万个动作，未丢弃旧保存事实。")
        }
        return complete
    }
}
