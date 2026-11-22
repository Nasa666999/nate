import Foundation
import NateCore

public struct RecoveryStorageBusy: Error, LocalizedError, Sendable {
    /// 业务作用：容量任务相互等待时反馈可重试状态，不把临时占用解释为恢复文件损坏。
    /// 参数说明: 无。
    /// 返回：当前目录已有写入或统计时的可读原因。
    public var errorDescription: String? {
        "恢复目录已有容量操作在进行，请稍后重试。"
    }
}

public struct RecoveryStorageCapacityError: Error, LocalizedError, Sendable {
    public let usedBytes: Int64
    public let requestedBytes: Int64
    public let maximumBytes: Int64

    /// 业务作用：超限反馈区分已有内容、本次临时空间与配置上限，保留全部可恢复材料。
    /// 参数说明: 无。
    /// 返回：可用于状态栏与设置入口的明确容量原因。
    public var errorDescription: String? {
        "恢复存储总量不足：已用或已预留 \(usedBytes) 字节，本次需临时 \(requestedBytes) 字节，上限 \(maximumBytes) 字节。"
            + "现有恢复内容继续保留；可提高上限或清理无引用的恢复内容。"
    }
}

final class RecoveryStorageLease: Sendable {
    private let key: Data
    private let token: UUID

    /// 业务作用：同一恢复目录的所有存储副本共享容量写入资格，不允许并行任务重复消费剩余空间。
    /// 参数说明:
    /// - directory: 已固定的实例恢复根目录。
    /// - deadline: 写入等待的共同截止，为空时只立即尝试一次。
    /// - permit: 等待期间仍有效的执行资格。
    /// 返回：取得可撤销的唯一目录资格；失权、截止或数量超量时拒绝并允许重试。
    init(
        directory: URL,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        key = Data(directory.path.utf8)
        token = UUID()
        try RecoveryStorageQueue.acquire(key: key, token: token, deadline: deadline, permit: permit)
    }

    /// 业务作用：仅当前动作自己的令牌可以归还目录资格，迟到释放不能解除后继任务的保护。
    /// 参数说明: 无。
    /// 返回：对应令牌仍有效时移除登记，重复释放不影响任何其它任务。
    func release() {
        RecoveryStorageQueue.release(key: key, token: token)
    }

    deinit {
        release()
    }
}
