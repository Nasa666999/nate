import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：以固定单调周期检查待保存状态，持续输入和菜单跟踪不重置周期。
    /// 参数说明: 无。
    /// 返回：只有一个有效调度任务；睡眠错过的周期合并处理。
    func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            [weak self] in
            let clock = ContinuousClock()
            var next = clock.now.advanced(by: .seconds(1))
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: next)
                }
                catch {
                    break
                }
                guard let self else {
                    break
                }
                self.scheduleInstanceRequests()
                if !self.closing && self.externalObservationTask == nil {
                    self.externalObservationTask = Task {
                        [weak self] in
                        guard let self else {
                            return
                        }
                        defer {
                            self.externalObservationTask = nil
                        }
                        await self.inspectExternalChanges(force: false)
                    }
                }
                if self.autosaveEnabled && !self.closing {
                    for document in self.documents
                    where !document.buffer.isReadOnly && document.url != nil && !document.conflict {
                        document.evaluateDirty()
                        if document.isDirty && document.nextRetry <= clock.now {
                            self.scheduleSave(document)
                        }
                    }
                }
                // 退出等待原文件或外部进程时，恢复通道仍独立保护冻结后的最新正文。
                if self.autosaveEnabled || self.closing {
                    self.scheduleRecovery(force: self.initialRecoveryConfirmation)
                    self.scheduleSidebarRecovery()
                }
                self.refreshUI()
                next = next.advanced(by: .seconds(1))
                if next < clock.now {
                    next = clock.now.advanced(by: .seconds(1))
                }
            }
        }
    }

    /// 业务作用：同一原文件同时只允许一个在途快照，后续修改由下一周期合并。
    /// 参数说明:
    /// - document: 具备有效目标的工作区文档。
    /// 返回：安排受身份、代次和磁盘基线约束的保存任务。
    func scheduleSave(_ document: WorkspaceDocument) {
        guard !document.bindingChange, document.saveTask == nil, let url = document.url,
            !document.buffer.isReadOnly,
            !document.conflict
        else {
            return
        }
        let snapshot = document.buffer.snapshot
        let changeSavePoint = document.buffer.changeHistorySavePoint()
        let encoding = document.encoding
        let baseline = document.baseline
        let generation = document.targetGeneration
        document.state = "保存中"
        let executor = fileIO
        let catalog = codecs
        let permit = CancellationToken()
        let request = fileOperations.begin(
            title: "保存原文件",
            target: url,
            documentID: snapshot.id,
            revision: snapshot.revision,
            targetGeneration: generation,
            permission: permit
        )
        document.savePermit = permit
        document.saveOperation = request
        document.saveTask = Task {
            [weak self, weak document] in
            guard let self, let document else {
                self?.fileOperations.complete(request, error: CancellationError())
                return false
            }
            defer {
                document.saveTask = nil
                document.savePermit = nil
                if document.saveOperation?.id == request.id {
                    document.saveOperation = nil
                }
                self.refreshUI()
            }
            do {
                let backup = try self.saveBackupRequest(request)
                let result = try await executor.run {
                    try self.fileOperations.perform(request) {
                        let bytes = try encoding.encode(snapshot.text.text(), catalog: catalog)
                        return try self.fileOperations.write(
                            using: self.fileAccess,
                            request: request,
                            bytes,
                            to: url,
                            expected: baseline,
                            backup: backup
                        )
                    }
                }
                // 旧生命周期和旧路径代次不得清除新文档的修改或错误。
                guard
                    self.documents.contains(where: {
                        $0 === document
                    }),
                    document.targetGeneration == generation
                else {
                    return false
                }
                document.baseline = result
                document.savedText = snapshot.text
                document.savedEncoding = encoding
                document.lastSavedRevision = snapshot.revision
                document.failure = nil
                document.retryCount = 0
                document.state = "已保存"
                // 保存 B 在途时撤销回 A，完成后仍需把 A 安排到后续周期。
                document.evaluateDirty()
                self.scheduleSavedModifications(changeSavePoint, document: document)
                return true
            }
            catch is CancellationError {
                self.fileOperations.complete(request, error: CancellationError())
                document.state = "原文件保存已取消 · 正文保留"
                document.evaluateDirty()
                return false
            }
            catch {
                self.fileOperations.complete(request, error: error)
                guard document.targetGeneration == generation else {
                    return false
                }
                document.failure = error.localizedDescription
                document.state = "原文件保存失败"
                document.dirtyHint = true
                document.conflict =
                    error.localizedDescription.contains("冲突") || error.localizedDescription.contains("外部变化")
                    || request.snapshot.requiresReconciliation
                document.retryCount = min(6, document.retryCount + 1)
                document.nextRetry = .now.advanced(by: .seconds(1 << document.retryCount))
                return false
            }
        }
        refreshUI()
    }

    /// 业务作用：主动保存等待最后修订落盘，不能把较早快照成功当作当前成功。
    /// 参数说明:
    /// - document: 需要收束原路径通道的文档。
    /// - deadline: 可选的整个关闭或退出动作共用截止时间。
    /// 返回：当前正文与实际磁盘保存点相同时为真；失败保留文档。
    func flush(_ document: WorkspaceDocument, deadline: ContinuousClock.Instant? = nil) async -> Bool {
        let deadline = deadline ?? .now.advanced(by: .seconds(30))
        guard
            await TaskBoundary.wait(
                until: deadline,
                while: {
                    document.bindingChange
                }
            )
        else {
            document.savePermit?.cancel()
            document.failure = "文件目标操作仍在进行，已停止等待；可在文件写入任务中查看实际状态。"
            return false
        }
        guard await waitForOriginalSave(document, until: deadline) else {
            return false
        }
        document.evaluateDirty()
        if !document.isDirty {
            return true
        }
        guard document.url != nil else {
            return await flushRecovery(deadline: deadline)
        }
        for _ in 0..<4 {
            guard ContinuousClock.now < deadline else {
                break
            }
            scheduleSave(document)
            guard document.saveTask != nil, await waitForOriginalSave(document, until: deadline) else {
                return false
            }
            guard document.failure == nil else {
                return false
            }
            document.evaluateDirty()
            if !document.isDirty {
                return true
            }
        }
        document.failure = "保存期间正文持续变化，请停止输入后重试关闭。"
        return false
    }

    /// 业务作用：等待同一原目标的真实写入返回，超时先撤销未使用权限而不释放在途写入位置。
    /// 参数说明:
    /// - document: 仍持有在途请求的文档。
    /// - deadline: 用户动作的共用截止时间。
    /// 返回：通道真正空闲时为真；超时保留任务、正文及目标预约。
    func waitForOriginalSave(_ document: WorkspaceDocument, until deadline: ContinuousClock.Instant? = nil)
        async -> Bool
    {
        let ended = await TaskBoundary.wait(until: deadline ?? .now.advanced(by: .seconds(30))) {
            document.saveTask != nil
        }
        guard ended else {
            // 撤销与发布门禁同步决定顺序；已经进入系统发布的请求仍须等待真实结果。
            document.savePermit?.cancel()
            document.failure = "原文件操作仍未返回，已停止等待并撤销尚未使用的发布权；正文继续保留。"
            refreshUI()
            return false
        }
        return true
    }

    /// 业务作用：原路径与恢复目录使用独立 I/O 通道，原文件失败不阻断保护副本。
    /// 参数说明:
    /// - force: 是否在退出等边界重新固定视图元数据。
    /// 返回：每份正文先同步，再可靠发布有序恢复索引。
    func scheduleRecovery(force: Bool = false) {
        if !recoveryStorage.loaded {
            loadRecoveryStoragePolicy()
        }
        guard recoveryReady, recoveryTask == nil, let store = recovery,
            force || ContinuousClock.now >= nextRecoveryRetry
        else {
            return
        }
        if let failure = recoveryStorage.failure {
            lastRecoverySucceeded = false
            for document in documents {
                document.recoveryError = "恢复存储设置未能解释，原内容保留：" + failure
            }
            return
        }
        let captured = documents
        let changed = captured.filter {
            $0.recoveryReference == nil || $0.recoveryRevision != $0.buffer.revision
                || $0.lastRecoveryMetadata != $0.recoveryMetadataKey
        }
        let metadataKeys = Dictionary(
            uniqueKeysWithValues: changed.map {
                ($0.buffer.id, $0.recoveryMetadataKey)
            }
        )
        let oldReferences = captured.compactMap(\.recoveryReference)
        let workspace = RecoveryWorkspaceState(
            documentIDs: captured.map {
                $0.buffer.id
            },
            activeID: activeID
        )
        guard
            !changed.isEmpty || oldReferences.count != captured.count || force
                || workspace != publishedRecoveryWorkspace
                || captured.contains(where: {
                    $0.recoveryError != nil
                })
        else {
            return
        }
        let payload: [(RecoveryDocument, PieceTree)] = changed.map {
            var metadata = $0.recoveryDocument()
            metadata.text = ""
            return (metadata, $0.buffer.text)
        }
        let ids = workspace.documentIDs
        let selected = workspace.activeID
        let byteCounts = captured.map {
            $0.buffer.text.byteCount
        }
        let executor = recoveryIO
        let ledger = recoveryProgress
        let progressID = ledger.begin(
            kind: .workspace,
            target: store.directory.appendingPathComponent("session.json"),
            names: Dictionary(
                uniqueKeysWithValues: payload.map {
                    ($0.0.id, $0.0.name)
                }
            ),
            totalDocuments: captured.count,
            totalBytes: payload.reduce(0) {
                $0 + $1.1.byteCount
            }
        )
        let observed = store.observingProgress {
            ledger.observe($0, id: progressID)
        }
        initialRecoveryConfirmation = false
        lastRecoverySucceeded = false
        recoveryTask = Task {
            [weak self] in
            guard let self else {
                ledger.finish(progressID, failure: "所属工作区已结束，本次恢复动作未开始。")
                return false
            }
            defer {
                self.recoveryTask = nil
                self.refreshUI()
            }
            do {
                let references = try await executor.run {
                    guard ids.count <= RecoveryLimits.documents else {
                        throw NateError.message("恢复工作区超过 1024 个文档预算。")
                    }
                    var bytes = 0
                    for count in byteCounts {
                        guard count <= RecoveryLimits.documentBytes,
                            count <= RecoveryLimits.workspaceBytes - bytes
                        else {
                            throw NateError.message("恢复正文超过单文档 1 GB 或工作区 2 GB 预算，现有记录保持原状。")
                        }
                        bytes += count
                    }
                    let deadline = ContinuousClock.now.advanced(by: RecoveryLimits.processingTime)
                    return try observed.withStorageWrite(deadline: deadline) {
                        store in
                        var references = Dictionary(
                            uniqueKeysWithValues: oldReferences.map {
                                ($0.id, $0)
                            }
                        )
                        for (metadata, tree) in payload {
                            references[metadata.id] = try store.checkpoint(
                                metadata: metadata,
                                text: tree,
                                deadline: deadline
                            )
                        }
                        let ordered = ids.compactMap {
                            references[$0]
                        }
                        try store.publish(ordered, active: selected)
                        return references
                    }
                }
                for (metadata, _) in payload {
                    guard
                        let document = self.documents.first(where: {
                            $0.buffer.id == metadata.id
                        })
                    else {
                        continue
                    }
                    document.recoveryReference = references[metadata.id]
                    document.recoveryRevision = metadata.revision
                    document.lastRecoveryMetadata = metadataKeys[metadata.id] ?? ""
                    if document.url == nil && document.buffer.revision == metadata.revision
                        && document.lastRecoveryMetadata == document.recoveryMetadataKey
                    {
                        document.state =
                            document.pendingOriginalPath == nil
                            ? "恢复内容已保存 · 尚未选择原文件" : "恢复内容已保存 · 原路径等待核验"
                        document.dirtyHint = false
                    }
                }
                for document in captured
                where self.documents.contains(where: {
                    $0 === document
                }) {
                    document.recoveryError = nil
                }
                // 回调只确认实际写出的工作区状态，等待期间的切换由下一周期继续发布。
                self.publishedRecoveryWorkspace = workspace
                self.lastRecoverySucceeded = true
                self.recoveryFailureCount = 0
                self.nextRecoveryRetry = .now
                self.refreshUI()
                // 两份有效索引及关闭保留清单之外的快照不再承担恢复责任。
                if ContinuousClock.now >= self.nextRecoveryCollection {
                    self.nextRecoveryCollection = .now.advanced(by: .seconds(60))
                    do {
                        try await executor.run {
                            try observed.collect(retention: 0)
                        }
                    }
                    catch {
                        self.lastRecoverySucceeded = false
                        self.recoveryFailureCount = min(6, self.recoveryFailureCount + 1)
                        self.nextRecoveryRetry = .now.advanced(by: .seconds(1 << self.recoveryFailureCount))
                        for document in captured {
                            document.recoveryError = "恢复索引已写出，后续依赖核验或清理未完成：" + error.localizedDescription
                        }
                        ledger.finish(progressID, failure: "恢复入口已确认，后续清理未完成：" + error.localizedDescription)
                        return false
                    }
                }
                ledger.finish(progressID)
                return true
            }
            catch {
                ledger.finish(
                    progressID,
                    failure: error.localizedDescription,
                    retry: error is RecoveryStorageBusy
                )
                self.recoveryFailureCount = min(6, self.recoveryFailureCount + 1)
                self.nextRecoveryRetry = .now.advanced(by: .seconds(1 << self.recoveryFailureCount))
                for document in captured {
                    document.recoveryError = error.localizedDescription
                }
                self.mainWindow?.status.stringValue = "恢复保存失败：" + error.localizedDescription
                return false
            }
        }
    }

    /// 业务作用：关闭、退出或会话保存前立即确认独立恢复通道。
    /// 参数说明:
    /// - deadline: 可选的整个用户动作共用截止时间。
    /// 返回：当前工作区索引可靠发布后为真。
    func flushRecovery(deadline: ContinuousClock.Instant? = nil) async -> Bool {
        let deadline = deadline ?? .now.advanced(by: .seconds(30))
        guard recoveryReady else {
            return false
        }
        guard
            await TaskBoundary.wait(
                until: deadline,
                while: {
                    recoveryTask != nil
                }
            )
        else {
            mainWindow?.status.stringValue = "恢复目录仍未返回，当前文档保持打开；未确认的内容不能作为关闭依据。"
            return false
        }
        scheduleRecovery(force: true)
        guard recoveryTask != nil,
            await TaskBoundary.wait(
                until: deadline,
                while: {
                    recoveryTask != nil
                }
            )
        else {
            return false
        }
        return lastRecoverySucceeded
    }
}
