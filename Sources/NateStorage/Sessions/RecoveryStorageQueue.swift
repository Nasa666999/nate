import Foundation
import NateCore
import os

private struct RecoveryStorageQueueState {
    var owners: [Data: UUID] = [:]
    var waiting: [Data: [UUID]] = [:]
    var waitingCount = 0
}

enum RecoveryStorageQueue {
    private static let state = OSAllocatedUnfairLock(initialState: RecoveryStorageQueueState())

    /// 业务作用：写入按已登记顺序有界等待，短暂只读统计不越过已有写入者，持续正文保存不能饿死侧栏。
    /// 参数说明:
    /// - key: 固定恢复根目录的原字节身份。
    /// - token: 当前动作独立令牌。
    /// - deadline: 写入等待的共同截止，为空时仅尝试立即取得资格。
    /// - permit: 等待期间仍有效的执行资格。
    /// 返回：当前动作取得唯一目录资格；失权、截止或等待数量超量时保留其它任务登记并失败。
    static func acquire(
        key: Data,
        token: UUID,
        deadline: ContinuousClock.Instant?,
        permit: @Sendable () -> Bool
    ) throws {
        guard !Task.isCancelled, permit() else {
            throw CancellationError()
        }
        if deadline == nil {
            let acquired = state.withLock {
                current in
                // 短暂只读查看不抢占已经排队的写入，否则持续统计也可能让恢复任务一直无法推进。
                guard current.owners[key] == nil, current.waiting[key]?.isEmpty != false,
                    current.owners.count + current.waiting.count < 1024
                else {
                    return false
                }
                current.owners[key] = token
                return true
            }
            guard acquired else {
                throw RecoveryStorageBusy()
            }
            return
        }
        let registered = state.withLock {
            current in
            guard current.waitingCount < 4096, (current.waiting[key]?.count ?? 0) < 1024,
                current.owners[key] != nil || current.waiting[key] != nil
                    || current.owners.count + current.waiting.count < 1024
            else {
                return false
            }
            current.waiting[key, default: []].append(token)
            current.waitingCount += 1
            return true
        }
        guard registered else {
            throw RecoveryStorageBusy()
        }
        var acquired = false
        defer {
            if !acquired {
                release(key: key, token: token)
            }
        }
        // 排队令牌先于取得资格登记，取消只移除自己的位置，不能让新动作越过已有等待者。
        while !acquired {
            guard !Task.isCancelled, permit() else {
                throw CancellationError()
            }
            guard let deadline, .now < deadline else {
                throw RecoveryStorageBusy()
            }
            acquired = state.withLock {
                current in
                // 只有队首且容器空闲时才能取得权威，新来的请求不能跳过已等待的恢复动作。
                guard current.owners[key] == nil, current.waiting[key]?.first == token else {
                    return false
                }
                current.waiting[key]?.removeFirst()
                current.waitingCount -= 1
                if current.waiting[key]?.isEmpty == true {
                    current.waiting.removeValue(forKey: key)
                }
                current.owners[key] = token
                return true
            }
            if !acquired {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    /// 业务作用：完成或取消只释放相同动作的持有和排队位置，后继动作的目录保护不被迟到回调解除。
    /// 参数说明:
    /// - key: 当前固定恢复根目录的原字节身份。
    /// - token: 本动作自己的令牌。
    /// 返回：自己的登记被移除，重复释放不影响其它持有者和等待者。
    static func release(key: Data, token: UUID) {
        state.withLock {
            current in
            if current.owners[key] == token {
                current.owners.removeValue(forKey: key)
            }
            if let index = current.waiting[key]?.firstIndex(of: token) {
                current.waiting[key]?.remove(at: index)
                current.waitingCount -= 1
                if current.waiting[key]?.isEmpty == true {
                    current.waiting.removeValue(forKey: key)
                }
            }
        }
    }
}
