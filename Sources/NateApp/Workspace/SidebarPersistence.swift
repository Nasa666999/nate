import AppKit
import NateStorage

extension ApplicationController {
    /// 业务作用：合并侧栏的尚未开始写入，只保护当前完整状态，独立于正文和原文件的等待。
    /// 参数说明:
    /// - force: 是否重新确认未变化的现有归档，退出收尾使用此值。
    /// 返回：已初始化且有覆盖资格时保持一个排空任务；归档异常时记录最新候选但不自动重建。
    func scheduleSidebarRecovery(force: Bool = false) {
        if !recoveryStorage.loaded {
            loadRecoveryStoragePolicy()
        }
        let runtime = sidebarRecovery
        guard !runtime.loading, let state = captureSidebarState(discardingDrafts: closing) else {
            return
        }
        if let failure = recoveryStorage.failure {
            runtime.pending = state
            runtime.failure = "恢复存储设置未能解释，当前侧栏保留：" + failure
            return
        }
        if !force && state == runtime.lastSaved {
            // 回到保存点也必须替换等待中的中间状态，正在发布的旧候选结束后只能写入最新选择。
            runtime.pending = runtime.task == nil ? nil : state
            if runtime.ready && runtime.task == nil {
                runtime.failure = nil
                runtime.lastAttempt = nil
            }
            return
        }
        guard force || runtime.task != nil || state != runtime.lastAttempt || runtime.failure == nil else {
            return
        }
        runtime.pending = state
        guard runtime.ready, recovery != nil, runtime.task == nil else {
            return
        }
        runtime.task = Task {
            [weak self] in
            await self?.drainSidebarRecovery()
        }
    }

    /// 业务作用：顺序确认每次实际发布的基线，后续状态不能沿旧证据越过新的关闭或放弃定义。
    /// 参数说明: 无。
    /// 返回：完整候选依次持久化；纯数据校验失败可由新候选继续，实际文件失败停止自动覆盖并保留当前界面。
    func drainSidebarRecovery() async {
        let runtime = sidebarRecovery
        defer {
            runtime.task = nil
        }
        while runtime.ready, let state = runtime.pending, let store = recovery {
            runtime.pending = nil
            runtime.lastAttempt = state
            do {
                _ = try await runtime.io.readCancellable {
                    token in
                    try token.check()
                    return try SidebarRecoveryArchive.encode(state)
                }
            }
            catch {
                runtime.failure = "当前侧栏未保存，完整定义保留：" + error.localizedDescription
                continue
            }
            do {
                let expected = runtime.baseline
                let baseline = try await runtime.io.runCancellable {
                    token in
                    try store.publishSidebars(
                        state,
                        expected: expected,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                // 实际发布确认后才推进保存点，队列中的更新随后取得新基线，不能把等待中的候选误记为已保存。
                runtime.baseline = baseline
                runtime.lastSaved = state
                runtime.failure = nil
            }
            catch is RecoveryStorageBusy {
                // 其它恢复动作暂时拥有容量资格不代表归档损坏，保留候选并由下一周期重新取得资格。
                runtime.pending = runtime.pending ?? state
                runtime.lastAttempt = nil
                runtime.failure = nil
                return
            }
            catch let error as RecoveryStorageCapacityError {
                // 容量拒绝发生在当前入口写入之前，原基线仍可复验；提高上限后可以继续同一候选。
                runtime.pending = runtime.pending ?? state
                runtime.failure = "侧栏恢复容量不足，当前定义继续保留：" + error.localizedDescription
                return
            }
            catch let error as RecoveryStoragePolicyFailure {
                // 策略拒绝没有取得文件写入权，修正设置后仍可沿原基线确认同一侧栏候选。
                runtime.pending = runtime.pending ?? state
                runtime.failure = "侧栏恢复设置未应用，当前定义继续保留：" + error.localizedDescription
                return
            }
            catch {
                // 文件结果不明时旧证据不再足够，保留当前候选并等待显式重建，不能自动覆盖异常归档。
                runtime.ready = false
                runtime.pending = runtime.pending ?? state
                runtime.failure = "侧栏保存未确认，原定义保留；可重新保存当前侧栏：" + error.localizedDescription
                return
            }
        }
    }

    /// 业务作用：退出前等待最后的侧栏快照，已确认放弃的草稿不能留在当前或上一份归档中。
    /// 参数说明:
    /// - deadline: 退出流程为本通道提供的等待截止。
    /// 返回：最终侧栏已经确认且无失败时为真；等待、损坏或保存失败为假，正文通道独立继续。
    func flushSidebarRecovery(until deadline: ContinuousClock.Instant) async -> Bool {
        scheduleSidebarRecovery(force: true)
        _ = await TaskBoundary.wait(
            until: deadline,
            while: {
                sidebarRecovery.task != nil
            }
        )
        return sidebarRecovery.task == nil && sidebarRecovery.ready && sidebarRecovery.failure == nil
            && sidebarRecovery.lastSaved == captureSidebarState(discardingDrafts: closing)
    }

    /// 业务作用：用户明确重新保存当前侧栏后取得新基线并替换两份恢复归档，不改变项目原文件与正文。
    /// 参数说明: 无。
    /// 返回：有界完整快照成功后恢复周期保护；仍有写入、关闭或读取失败时保留归档并说明原因。
    func resetSidebarRecovery() {
        let runtime = sidebarRecovery
        guard !closing, !runtime.loading, runtime.task == nil, let store = recovery,
            let state = captureSidebarState()
        else {
            return
        }
        runtime.ready = false
        // 显式重建先撤销旧恢复读取，再取得当前磁盘证据，旧读取不能迟到重新授予覆盖权。
        runtime.generation = UUID()
        runtime.task = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                runtime.task = nil
                if runtime.ready {
                    // 重建等待期间可能已有新的关闭或定义意图，结束后重新捕获当前状态，不能丢掉最终退出快照。
                    runtime.pending = nil
                    self.scheduleSidebarRecovery()
                }
            }
            do {
                let baseline = try await runtime.io.readCancellable {
                    token in
                    try token.check()
                    _ = try SidebarRecoveryArchive.encode(state)
                    return try store.sidebarBaseline(permit: {
                        !token.isCancelled
                    })
                }
                let published = try await runtime.io.runCancellable {
                    token in
                    try store.publishSidebars(
                        state,
                        expected: baseline,
                        rebuilding: true,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                runtime.baseline = published
                runtime.lastSaved = state
                runtime.lastAttempt = nil
                runtime.pending = nil
                runtime.ready = true
                runtime.failure = nil
                self.mainWindow?.status.stringValue = "当前侧栏已重新保存，周期恢复保护已启用。"
            }
            catch {
                runtime.failure = "侧栏重新保存未确认，当前定义保留：" + error.localizedDescription
                self.mainWindow?.status.stringValue = runtime.failure ?? ""
            }
        }
    }
}
