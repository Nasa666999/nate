import Foundation

public enum ModificationEdition: Int, Sendable, CaseIterable {
    case revertedOriginal = 1
    case saved = 2
    case unsaved = 3
    case revertedChange = 4
}

public struct DocumentModificationRun: Sendable {
    public let range: ByteRange
    public let edition: ModificationEdition
}

public struct DocumentModificationDeletion: Sendable {
    public let position: Int
    public let editions: [ModificationEdition]
}

public struct DocumentModificationSnapshot: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let generation: UUID
    let state: ChangeHistoryState

    /// 业务作用：修改呈现只取得同一正文修订的不可变证据，不具备正文或保存点修改权。
    /// 参数说明:
    /// - documentID: 所属文档生命周期。
    /// - revision: 同一正文的单调修订。
    /// - generation: 同一修订内保存分类改变时也推进的发布身份。
    /// - state: 已完成整份发布的原生修改类别。
    /// 返回：可供后台导航与当前绘制共享的固定呈现快照。
    init(documentID: UUID, revision: UInt64, generation: UUID, state: ChangeHistoryState) {
        self.documentID = documentID
        self.revision = revision
        self.generation = generation
        self.state = state
    }

    /// 业务作用：在有限可见范围内按连续类别返回完整修改区间，长段原文不逐字节展开。
    /// 参数说明:
    /// - range: 与快照正文对应的原字节范围。
    /// - maximumCount: 允许返回的完整区间数量，上限 65536。
    /// - deadline: 整份呈现查询的共同截止。
    /// - permit: 所属正文和呈现仍有效。
    /// 返回：完整有序修改区间，超量或失去来源时不返回部分结果。
    public func runs(
        in range: ByteRange,
        maximumCount: Int = 4096,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> [DocumentModificationRun] {
        try validate(range, maximumCount: maximumCount)
        let work = ChangeHistoryWork(deadline: deadline, permit: permit)
        var result: [DocumentModificationRun] = []
        var cursor = range.lower
        while cursor < range.upper {
            try work.check()
            let end = min(range.upper, state.endRun(at: cursor))
            guard end > cursor else {
                throw NateError.message("修改历史区间无法完整推进，未返回部分显示。")
            }
            if let edition = ModificationEdition(rawValue: state.edition(at: cursor)) {
                guard result.count < maximumCount else {
                    throw NateError.message("修改历史可见区间超过当前呈现容量，未返回截断显示。")
                }
                result.append(DocumentModificationRun(range: ByteRange(cursor, end), edition: edition))
            }
            cursor = end
        }
        try work.check()
        return result
    }

    /// 业务作用：删除正文后仍在真实锚点显示完整历史，文件末尾或空文件的删除不被丢弃。
    /// 参数说明:
    /// - range: 当前原字节范围，包含两端的删除锚点。
    /// - maximumCount: 允许返回的完整删除位置数量，上限 65536。
    /// - deadline: 整份呈现查询的共同截止。
    /// - permit: 所属正文和呈现仍有效。
    /// 返回：有序锚点及各自全部类别；超量、取消或失去来源时整体拒绝。
    public func deletions(
        in range: ByteRange,
        maximumCount: Int = 4096,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> [DocumentModificationDeletion] {
        try validate(range, maximumCount: maximumCount)
        let work = ChangeHistoryWork(deadline: deadline, permit: permit)
        var result: [DocumentModificationDeletion] = []
        var cursor = range.lower
        while cursor <= range.upper {
            try work.check()
            let editions = Self.editions(mask: state.deletionEditions(at: cursor))
            if !editions.isEmpty {
                guard result.count < maximumCount else {
                    throw NateError.message("修改历史可见删除位置超过当前呈现容量，未返回截断显示。")
                }
                result.append(DocumentModificationDeletion(position: cursor, editions: editions))
            }
            cursor = state.nextDeletion(after: cursor)
        }
        try work.check()
        return result
    }

    /// 业务作用：行边栏联合正文区间与删除锚点，保留同一行同时存在的不同修改状态。
    /// 参数说明:
    /// - range: 包含实际物理换行的完整逻辑行范围。
    /// - bodyEnd: 该行不含物理换行的末端，删除锚点只计到这里。
    /// - deadline: 行类别查询的共同截止。
    /// 返回：该行的全部原生类别；非法行边界或超量时拒绝猜测单一颜色。
    public func editions(
        in range: ByteRange,
        bodyEnd: Int,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws -> [ModificationEdition] {
        guard bodyEnd >= range.lower, bodyEnd <= range.upper else {
            throw NateError.message("修改历史行结束证据无效，未显示另一行的类别。")
        }
        try validate(range, maximumCount: 4096)
        let work = ChangeHistoryWork(deadline: deadline)
        var mask = 0
        var cursor = range.lower
        while cursor < range.upper, mask != 15 {
            try work.check()
            let edition = state.edition(at: cursor)
            if edition > 0 {
                mask |= 1 << (edition - 1)
            }
            let next = state.endRun(at: cursor)
            guard next > cursor else {
                throw NateError.message("修改历史行区间无法推进，未返回部分分类。")
            }
            cursor = next
        }
        cursor = range.lower
        while cursor <= bodyEnd, mask != 15 {
            try work.check()
            mask |= state.deletionEditions(at: cursor)
            cursor = state.nextDeletion(after: cursor)
        }
        try work.check()
        return Self.editions(mask: mask)
    }

    /// 业务作用：修改导航按真实字节区间和删除位置寻找后继或前驱，不扫描全部文件行。
    /// 参数说明:
    /// - position: 向前包含此位置，向后只查询此位置之前；允许末尾加一。
    /// - backwards: 为真查询前驱，否则查询后继。
    /// - deadline: 整份导航查询的共同截止。
    /// - permit: 当前文档、选择和导航意图仍有效。
    /// 返回：最近的原字节证据供调用方定位逻辑行；没有候选时为空，超时或失权整体拒绝。
    public func nearestPosition(
        from position: Int,
        backwards: Bool,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Int? {
        guard position >= 0, position <= state.length + 1 else {
            throw NateError.message("修改历史导航起点不属于当前正文。")
        }
        let work = ChangeHistoryWork(deadline: deadline, permit: permit)
        var result: Int?
        for log in [state.log, state.reversions].compactMap({
            $0
        }) {
            for (index, run) in log.runs.values.enumerated() {
                if index & 255 == 0 {
                    try work.check()
                }
                guard run.edition != 0 else {
                    continue
                }
                if backwards, run.lower < position {
                    result = max(result ?? 0, min(run.upper - 1, position - 1))
                }
                else if !backwards, run.upper > position {
                    result = min(result ?? state.length, max(run.lower, position))
                }
            }
            for (index, deletion) in log.deletions.enumerated() {
                if index & 255 == 0 {
                    try work.check()
                }
                if backwards, deletion.position < position {
                    result = max(result ?? 0, deletion.position)
                }
                else if !backwards, deletion.position >= position {
                    result = min(result ?? state.length, deletion.position)
                }
            }
        }
        try work.check()
        return result
    }

    /// 业务作用：查询只接受完整正文内范围及有限结果容量，不能用截断范围伪装另一份证据。
    /// 参数说明:
    /// - range: 当前正文内的完整原字节范围。
    /// - maximumCount: 当前调用明确采用的结果上限。
    /// 返回：范围和容量全部合法时通过，否则拒绝查询。
    private func validate(_ range: ByteRange, maximumCount: Int) throws {
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= state.length,
            (1...65_536).contains(maximumCount)
        else {
            throw NateError.message("修改历史查询范围或容量无效，未返回部分结果。")
        }
    }

    /// 业务作用：四类位集合以固定原生顺序呈现，多类删除或同一行混合状态不能互相覆盖。
    /// 参数说明:
    /// - mask: 已验证内部状态产生的四位类别集合。
    /// 返回：全部有效类别，空集合不产生虚构修改。
    private static func editions(mask: Int) -> [ModificationEdition] {
        ModificationEdition.allCases.filter {
            mask & (1 << ($0.rawValue - 1)) != 0
        }
    }
}
