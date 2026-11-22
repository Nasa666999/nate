import Foundation
import NateCore

extension RecoveryStore {
    /// 业务作用：策略变更只影响未来恢复动作，在途操作继续持有自己已固定的预算。
    /// 参数说明:
    /// - policy: 用户明确采用的新总量策略。
    /// 返回：共享正文摘要缓存的新存储值，不删除内容、不改变已取得的写入资格。
    public func applyingStoragePolicy(_ policy: RecoveryStoragePolicy) throws -> RecoveryStore {
        try policy.validate()
        var copy = self
        copy.storagePolicy = policy
        copy.storageBudget = nil
        return copy
    }

    /// 业务作用：多个检查点与索引在同一同步动作内共享目录资格、实际占用和临时空间预留。
    /// 参数说明:
    /// - deadline: 整个恢复动作的共同截止，为空时最多三十秒。
    /// - permit: 准备容量统计时的继续执行资格，文件发布仍复验各自权限。
    /// - operation: 同步使用受控存储的完整恢复动作，离开后该副本不再授权写入。
    /// 返回：完整动作的返回值；失权、竞争或超量失败会保留原可恢复入口。
    public func withStorageWrite<Value>(
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        },
        operation: (RecoveryStore) throws -> Value
    ) throws -> Value {
        if let storageBudget {
            guard storageBudget.allowed else {
                throw NateError.message("恢复容量动作已结束，旧存储副本不能继续写入。")
            }
            return try operation(self)
        }
        try storagePolicy.validate()
        let deadline = min(
            deadline ?? .now.advanced(by: RecoveryLimits.processingTime),
            .now.advanced(by: RecoveryLimits.processingTime)
        )
        try checkRecoveryBudget(deadline, permit: permit)
        // 目录资格先于统计取得，所有合作写入共用同一容量来源，不能分别消费相同余额。
        let lease = try RecoveryStorageLease(directory: directory, deadline: deadline, permit: permit)
        let inventory = try storageInventory(deadline: deadline, permit: permit)
        let budget = RecoveryWriteBudget(
            inventory: inventory,
            maximumBytes: storagePolicy.maximumBytes,
            deadline: deadline,
            lease: lease
        )
        var copy = self
        copy.storageBudget = budget
        defer {
            budget.close()
        }
        return try operation(copy)
    }

    /// 业务作用：设置界面读取当前实例的实际逻辑占用，不读取正文、不沿文件链接进入外部路径。
    /// 参数说明:
    /// - permit: 当前统计展示请求的继续执行资格。
    /// 返回：五秒及 131072 个条目以内的文件总量与数量，已有任务、链接或目录变化时拒绝旧统计。
    public func storageUsage(
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> RecoveryStorageUsage {
        let lease = try RecoveryStorageLease(directory: directory)
        defer {
            lease.release()
        }
        let inventory = try storageInventory(deadline: .now.advanced(by: .seconds(5)), permit: permit)
        return RecoveryStorageUsage(
            bytes: inventory.bytes,
            files: inventory.files.count
        )
    }

    /// 业务作用：恢复文件共用完整临时空间预留和发布权限，不能由某个索引或侧栏路径绕过总量。
    /// 参数说明:
    /// - data: 完整待写入字节。
    /// - url: 当前固定容器内的精确文件目标。
    /// - expected: 已验证的原文件基线，空值要求目标不存在。
    /// - permit: 本文件动作继续发布的资格。
    /// 返回：完整同步后的新基线；失败关闭本次预算资格，原字节证据交由后续读取复验。
    func saveRecoveryData(
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        guard let budget = storageBudget else {
            throw NateError.message("恢复写入缺少完整容量动作，未发布新内容。")
        }
        // 完整临时空间先于文件创建预留，容量拒绝不能让目标入口留下半份新内容。
        let token = try budget.reserve(bytes: Int64(data.count), url: url, store: self, permit: permit)
        do {
            let result = try FileStorage.save(
                data,
                to: url,
                expected: expected,
                permit: {
                    permit() && budget.allowed
                }
            )
            // 原子替换与适用同步确认后才释放旧文件占用，失败阶段不能提前归还容量。
            budget.finish(token, succeeded: true)
            return result
        }
        catch {
            budget.finish(token, succeeded: false)
            throw error
        }
    }
}
