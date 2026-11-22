import Foundation
import NateCore
import os

private struct RecoveryWriteReservation: Sendable {
    let key: Data
    let oldBytes: Int64
    let newBytes: Int64
}

private struct RecoveryWriteBudgetState {
    var inventory: RecoveryStorageInventory
    var used: Int64
    var reservations: [UUID: RecoveryWriteReservation] = [:]
    var targets: Set<Data> = []
    var closed = false
    var invalid = false
}

final class RecoveryWriteBudget: Sendable {
    let deadline: ContinuousClock.Instant
    private let maximumBytes: Int64
    private let lease: RecoveryStorageLease
    private let state: OSAllocatedUnfairLock<RecoveryWriteBudgetState>

    /// 业务作用：同一同步恢复动作共享已统计占用与临时预留，原子替换完成前同时计算新旧内容。
    /// 参数说明:
    /// - inventory: 已取得目录资格之后的完整文件统计。
    /// - maximumBytes: 本轮固定总量上限。
    /// - deadline: 整个动作的共同截止。
    /// - lease: 当前目录的唯一容量资格。
    /// 返回：可跨存储副本共享的预算；离开所属动作后禁止新的写入。
    init(
        inventory: RecoveryStorageInventory,
        maximumBytes: Int64,
        deadline: ContinuousClock.Instant,
        lease: RecoveryStorageLease
    ) {
        self.deadline = deadline
        self.maximumBytes = maximumBytes
        self.lease = lease
        state = OSAllocatedUnfairLock(
            initialState: RecoveryWriteBudgetState(
                inventory: inventory,
                used: inventory.bytes
            )
        )
    }

    var allowed: Bool {
        !Task.isCancelled && .now < deadline
            && state.withLock {
                !$0.closed && !$0.invalid
            }
    }

    /// 业务作用：进入文件写入前复验目录并预留全部临时内容，容量不足不能触及目标文件。
    /// 参数说明:
    /// - bytes: 本次完整新内容的逻辑字节数。
    /// - url: 当前动作内的精确目标。
    /// - store: 当前固定恢复容器。
    /// - permit: 该文件请求的继续执行资格。
    /// 返回：独立预留令牌；目录变化、重复目标、失权或超量时拒绝新副作用。
    func reserve(
        bytes: Int64,
        url: URL,
        store: RecoveryStore,
        permit: @Sendable () -> Bool
    ) throws -> UUID {
        try store.checkRecoveryBudget(deadline, permit: permit)
        _ = try store.recoveryParent(url)
        return try state.withLock {
            current in
            guard !current.closed, !current.invalid, bytes >= 0 else {
                throw NateError.message("恢复容量动作已结束或存在未确认写入，未发布新内容。")
            }
            try qualify(&current, store: store, permit: permit)
            let key = Data(url.path.utf8)
            guard !current.targets.contains(key) else {
                throw RecoveryStorageBusy()
            }
            // 原子替换前新旧内容同时存在，必须按峰值预留，不能只比较替换之后的净增长。
            guard current.used <= maximumBytes, bytes <= maximumBytes - current.used else {
                throw RecoveryStorageCapacityError(
                    usedBytes: current.used,
                    requestedBytes: bytes,
                    maximumBytes: maximumBytes
                )
            }
            let token = UUID()
            current.used += bytes
            current.targets.insert(key)
            current.reservations[token] = RecoveryWriteReservation(
                key: key,
                oldBytes: current.inventory.files[key] ?? 0,
                newBytes: bytes
            )
            return token
        }
    }

    /// 业务作用：相同字节复用和目录同步也必须属于原容量容器，不能只在新文件写入时检查身份。
    /// 参数说明:
    /// - store: 本动作固定的恢复容器。
    /// 返回：当前动作仍有效且目录身份一致；新建目录完整重估后可用，变更或失权时拒绝入口确认。
    func verifyContainers(store: RecoveryStore) throws {
        let deadline = self.deadline
        let permit: @Sendable () -> Bool = {
            !Task.isCancelled && .now < deadline
        }
        try store.checkRecoveryBudget(deadline, permit: permit)
        try state.withLock {
            current in
            guard !current.closed, !current.invalid else {
                throw NateError.message("恢复动作已结束或存在未确认写入，不能确认新的恢复入口。")
            }
            try qualify(&current, store: store, permit: permit)
        }
    }

    /// 业务作用：锁内统一确认恢复根与分块容器，合法新建目录只在没有在途预留时重新统计。
    /// 参数说明:
    /// - current: 当前动作的锁内预算状态。
    /// - store: 当前固定恢复目录。
    /// - permit: 不反向读取本预算锁的独立请求资格。
    /// 返回：原容器保持一致，或新建容器完成实际占用重估；其它变化不改变原身份授权。
    private func qualify(
        _ current: inout RecoveryWriteBudgetState,
        store: RecoveryStore,
        permit: @Sendable () -> Bool
    ) throws {
        var refresh = false
        for directory in [store.directory, store.chunksDirectory] {
            let key = Data(directory.path.utf8)
            let observed = try store.storageDirectoryIdentity(directory)
            if let expected = current.inventory.directories[key] {
                guard observed == expected else {
                    throw NateError.message("恢复目录身份已经变化，旧容量资格不能用于新容器。")
                }
            }
            else if observed != nil {
                refresh = true
            }
        }
        if refresh {
            guard current.reservations.isEmpty else {
                throw RecoveryStorageBusy()
            }
            // 缺失目录由合法恢复动作建立后，首次使用重新统计，不能沿空目录的旧估计授权容量。
            current.inventory = try store.storageInventory(deadline: deadline, permit: permit)
            current.used = current.inventory.bytes
        }
        guard current.inventory.directories[Data(store.directory.path.utf8)] != nil else {
            throw NateError.message("恢复动作缺少已经建立并确认的目录，未发布新内容。")
        }
    }

    /// 业务作用：只有完整原子写入确认后才释放被替换内容的占用，失败不猜测文件是否已经发布。
    /// 参数说明:
    /// - token: 本文件写入前取得的独立容量令牌。
    /// - succeeded: 文件内容与适用目录同步是否已经确认完成。
    /// 返回：成功更新逻辑占用，失败关闭后续预算资格；迟到或重复完成不改变其它预留。
    func finish(_ token: UUID, succeeded: Bool) {
        let release = state.withLock {
            current in
            guard let reservation = current.reservations.removeValue(forKey: token) else {
                return false
            }
            current.targets.remove(reservation.key)
            if succeeded {
                current.used -= reservation.oldBytes
                current.inventory.files[reservation.key] = reservation.newBytes
                current.inventory.bytes = current.used
            }
            else {
                // 文件结果未知时保留全部预留，后续任务必须重新统计实际容器，不能继续消费旧余额。
                current.invalid = true
            }
            return current.closed && current.reservations.isEmpty
        }
        if release {
            lease.release()
        }
    }

    /// 业务作用：同步动作结束立即撤销后续写入资格，在途文件收束前继续保有目录容量保护。
    /// 参数说明: 无。
    /// 返回：无在途预留时归还目录资格；逸出的存储副本不能再启动新写入。
    func close() {
        let release = state.withLock {
            current in
            // 先撤销逸出副本的后续写入资格，已有文件收束前仍保有目录的唯一容量权。
            current.closed = true
            return current.reservations.isEmpty
        }
        if release {
            lease.release()
        }
    }

    deinit {
        close()
    }
}
