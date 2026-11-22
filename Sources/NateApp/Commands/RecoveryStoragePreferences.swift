import Foundation
import NateCore
import NateStorage

private struct RecoveryStorageConfiguration: Codable {
    var format = 1
    let policy: RecoveryStoragePolicy
}

@MainActor final class RecoveryStorageRuntime {
    var loaded = false
    var policy = RecoveryStoragePolicy()
    var failure: String?
    var generation = UUID()
    var dialogGeneration: UUID?
}

extension ApplicationController {
    /// 业务作用：恢复总量配置不可解释时停止新恢复写入，已有快照仍能读取，不采用更宽松的默认值。
    /// 参数说明: 无。
    /// 返回：完整策略用于未来动作；未知或损坏配置保留原偏好并在设置中展示原因。
    func loadRecoveryStoragePolicy() {
        let runtime = recoveryStorage
        runtime.loaded = true
        runtime.policy = RecoveryStoragePolicy()
        runtime.failure = nil
        do {
            if let value = configurationDefaults().object(forKey: "recoveryStoragePolicy") {
                guard let data = value as? Data, data.count <= 4096 else {
                    throw NateError.message("恢复存储设置不是完整受限数据。")
                }
                try UserConfigurationJSON.validate(data)
                runtime.policy = try UserConfigurationSchema.payload(
                    RecoveryStoragePolicy.self,
                    from: data,
                    field: "policy"
                )
            }
            try runtime.policy.validate()
            recovery = try recovery?.applyingStoragePolicy(runtime.policy)
        }
        catch {
            runtime.failure = error.localizedDescription
            if let store = recovery {
                // 未知配置可能原本有更严格上限，所有写入入口都必须失去默认容量资格，读取继续可用。
                recovery = RecoveryStore(
                    directory: store.directory,
                    storagePolicy: RecoveryStoragePolicy(maximumBytes: 0)
                )
            }
        }
        runtime.generation = UUID()
    }

    /// 业务作用：完整新策略先验证，再一起保存偏好与未来存储值，不改写正在进行的恢复动作。
    /// 参数说明:
    /// - policy: 用户明确采用的完整总量策略。
    /// 返回：合法策略持久保存并安排后续恢复；失败保持原设置及已提交内容。
    func saveRecoveryStoragePolicy(_ policy: RecoveryStoragePolicy) throws {
        try policy.validate()
        let updated = try recovery?.applyingStoragePolicy(policy)
        let data = try JSONEncoder().encode(RecoveryStorageConfiguration(policy: policy))
        guard data.count <= 4096 else {
            throw NateError.message("恢复存储配置超过容量，现有设置未改变。")
        }
        configurationDefaults().set(data, forKey: "recoveryStoragePolicy")
        recovery = updated
        recoveryStorage.loaded = true
        recoveryStorage.policy = policy
        recoveryStorage.failure = nil
        recoveryStorage.generation = UUID()
        nextRecoveryRetry = .now
        recoveryFailureCount = 0
        if sidebarRecovery.ready {
            // 容量或临时占用未改变原入口基线；文件异常造成的停止状态不能由设置动作解除。
            sidebarRecovery.lastAttempt = nil
            scheduleSidebarRecovery(force: true)
        }
        scheduleRecovery(force: true)
    }
}
