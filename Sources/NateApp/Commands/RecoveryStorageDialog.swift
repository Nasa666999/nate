import AppKit
import NateCore
import NatePlatform
import NateStorage
import os

private enum RecoveryUsageResult: Sendable {
    case value(RecoveryStorageUsage)
    case failure(String)
}

extension ApplicationController {
    /// 业务作用：提供恢复总量的明确设置入口，取消不保存，现有恢复内容不因降低上限而删除。
    /// 参数说明: 无。
    /// 返回：展示当前策略、后台实际用量及无引用内容清理入口。
    func showRecoveryStoragePreferences() {
        presentRecoveryStoragePreferences(draft: nil)
    }

    /// 业务作用：恢复容量表单保持清理前的草稿，后台统计不阻塞编辑或覆盖较新的配置。
    /// 参数说明:
    /// - draft: 清理前尚未应用的容量文字，为空时使用当前策略。
    /// 返回：明确应用后保存完整策略；取消或来源变化保留原设置。
    private func presentRecoveryStoragePreferences(draft: String?) {
        guard !closing else {
            return
        }
        if !recoveryStorage.loaded {
            loadRecoveryStoragePolicy()
        }
        let runtime = recoveryStorage
        let generation = UUID(), policyGeneration = runtime.generation
        let domain = configurationDefaults()
        let original = domain.object(forKey: "recoveryStoragePolicy") as? NSObject
        runtime.dialogGeneration = generation
        let alert = NSAlert()
        alert.messageText = "恢复存储设置"
        alert.informativeText =
            "上限适用于当前实例的文档、关闭内容和侧栏恢复文件，默认 8192 MiB。降低上限不会删除已有内容；后续任务空间不足时保留原恢复入口。原子写入需要同时容纳新旧内容。原文件与保存前备份另行管理。"
        if let failure = runtime.failure {
            alert.informativeText += "\n现有设置无法解释：" + failure + "\n明确应用将采用下方策略。"
        }
        let limit = NSTextField(string: draft ?? String(runtime.policy.maximumBytes / 1_048_576))
        limit.setAccessibilityLabel("恢复存储总量上限 MiB")
        limit.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let usage = NSTextField(wrappingLabelWithString: recovery == nil ? "恢复目录尚未连接。" : "正在统计当前用量…")
        usage.setAccessibilityLabel("恢复存储实际用量")
        usage.widthAnchor.constraint(equalToConstant: 430).isActive = true
        let cleanup = NSTextField(
            wrappingLabelWithString: "清理只移除不再被两份工作区索引或关闭历史引用的内容，未知或损坏依赖会停止清理。"
        )
        cleanup.widthAnchor.constraint(equalToConstant: 430).isActive = true
        let view = NSStackView(views: [
            NSTextField(labelWithString: "逻辑文件总量 MiB（1–1048576）"), limit, usage, cleanup,
        ])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 9
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: 440,
            height: 150
        )
        alert.accessoryView = view
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清理无引用内容")
        let executor = readIO
        let result = OSAllocatedUnfairLock<RecoveryUsageResult?>(initialState: nil)
        let task = recovery.map {
            store in
            Task.detached {
                let outcome: RecoveryUsageResult
                do {
                    let usage = try await executor.readCancellable {
                        token in
                        try store.storageUsage(permit: {
                            !token.isCancelled
                        })
                    }
                    outcome = .value(usage)
                }
                catch {
                    outcome = .failure(error.localizedDescription)
                }
                if !Task.isCancelled {
                    result.withLock {
                        $0 = outcome
                    }
                }
            }
        }
        // 读取不依赖主线程任务重入，模态确认期间也必须展示已经完成的用量；关闭后立即解除展示资格。
        let poll = Timer(timeInterval: 0.05, repeats: true) {
            [weak self, weak usage] timer in
            let completed = MainActor.assumeIsolated {
                guard let self, !self.closing, self.recoveryStorage.dialogGeneration == generation,
                    self.recoveryStorage.generation == policyGeneration
                else {
                    return true
                }
                let outcome = result.withLock {
                    value in
                    let current = value
                    value = nil
                    return current
                }
                guard let outcome else {
                    return false
                }
                switch outcome {
                case .value(let current):
                    usage?.stringValue =
                        "当前用量："
                        + ByteCountFormatter.string(fromByteCount: current.bytes, countStyle: .binary)
                        + "，\(current.files) 个文件。"
                case .failure(let reason):
                    usage?.stringValue = "当前用量未能确认：" + reason
                }
                return true
            }
            if completed {
                timer.invalidate()
            }
        }
        RunLoop.main.add(poll, forMode: .modalPanel)
        defer {
            poll.invalidate()
            task?.cancel()
            if runtime.dialogGeneration == generation {
                runtime.dialogGeneration = nil
            }
        }
        let choice = alert.runModal()
        guard choice != .alertSecondButtonReturn else {
            return
        }
        let current = domain.object(forKey: "recoveryStoragePolicy") as? NSObject
        // 模态期间来源可能更新，旧表单不能覆盖新的容量约束或发起旧来源的清理动作。
        guard !closing, configurationDefaults() === domain, runtime.generation == policyGeneration,
            original == nil && current == nil || original?.isEqual(current) == true
        else {
            SystemIntegration.alert("恢复设置未应用", "设置来源已经改变，请重新打开设置。")
            return
        }
        if choice == .alertThirdButtonReturn {
            let draft = limit.stringValue
            Task {
                await cleanRecoveryStorage(draft: draft)
            }
            return
        }
        guard choice == .alertFirstButtonReturn else {
            return
        }
        do {
            guard let mebibytes = Int64(limit.stringValue), (1...1_048_576).contains(mebibytes) else {
                throw NateError.message("请填写 1–1048576 范围内的整数 MiB。")
            }
            try saveRecoveryStoragePolicy(RecoveryStoragePolicy(maximumBytes: mebibytes * 1_048_576))
            mainWindow?.status.stringValue = "恢复存储上限已应用；已有内容保留，后续任务采用新上限。"
        }
        catch {
            SystemIntegration.alert("恢复设置未应用", error.localizedDescription)
        }
    }

    /// 业务作用：用户明确选择后后台核验全部恢复依赖，仅清理精确无引用内容并保留表单草稿。
    /// 参数说明:
    /// - draft: 用户尚未应用的容量文字。
    /// 返回：清理成功后重新统计并展示设置；失败保留恢复材料并反馈，退出后不重开窗口。
    private func cleanRecoveryStorage(draft: String) async {
        guard !closing, let store = recovery else {
            return
        }
        mainWindow?.status.stringValue = "正在核验恢复依赖并清理无引用内容…"
        do {
            try await recoveryIO.run {
                try store.collect(retention: 0)
            }
            guard !closing, recovery?.directory.path.utf8.elementsEqual(store.directory.path.utf8) == true
            else {
                return
            }
            nextRecoveryRetry = .now
            scheduleRecovery(force: true)
            mainWindow?.status.stringValue = "无引用恢复内容已清理，受保护内容继续保留。"
            presentRecoveryStoragePreferences(draft: draft)
        }
        catch {
            guard !closing else {
                return
            }
            SystemIntegration.alert("恢复清理未完成", error.localizedDescription)
            presentRecoveryStoragePreferences(draft: draft)
        }
    }
}
