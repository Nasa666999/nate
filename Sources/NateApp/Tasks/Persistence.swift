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
                if self.autosaveEnabled && !self.closing {
                    for document in self.documents
                    where !document.buffer.isReadOnly && document.url != nil && !document.conflict {
                        document.evaluateDirty()
                        if document.isDirty && document.nextRetry <= clock.now {
                            self.scheduleSave(document)
                        }
                    }
                    self.scheduleRecovery()
                }
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
        guard document.saveTask == nil, let url = document.url, !document.buffer.isReadOnly,
            !document.conflict
        else {
            return
        }
        let snapshot = document.buffer.snapshot
        let encoding = document.encoding
        let baseline = document.baseline
        let generation = document.targetGeneration
        document.state = "保存中"
        let executor = fileIO
        document.saveTask = Task {
            [weak self, weak document] in
            guard let self, let document else {
                return false
            }
            defer {
                document.saveTask = nil
                self.refreshUI()
            }
            do {
                let result = try await executor.run {
                    let bytes = try encoding.encode(snapshot.text.text())
                    return try FileStorage.save(bytes, to: url, expected: baseline)
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
                return true
            }
            catch {
                guard document.targetGeneration == generation else {
                    return false
                }
                document.failure = error.localizedDescription
                document.state = "原文件保存失败"
                document.dirtyHint = true
                document.conflict =
                    error.localizedDescription.contains("冲突") || error.localizedDescription.contains("外部变化")
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
    /// 返回：当前正文与实际磁盘保存点相同时为真；失败保留文档。
    func flush(_ document: WorkspaceDocument) async -> Bool {
        if let task = document.saveTask {
            _ = await task.value
        }
        document.evaluateDirty()
        if !document.isDirty {
            return true
        }
        guard document.url != nil else {
            return await flushRecovery()
        }
        for _ in 0..<4 {
            scheduleSave(document)
            guard let task = document.saveTask, await task.value else {
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

    /// 业务作用：原路径与恢复目录使用独立 I/O 通道，原文件失败不阻断保护副本。
    /// 参数说明:
    /// - force: 是否在退出等边界重新固定视图元数据。
    /// 返回：每份正文先同步，再可靠发布有序恢复索引。
    func scheduleRecovery(force: Bool = false) {
        guard recoveryTask == nil, let store = recovery else {
            return
        }
        let captured = documents
        let changed = captured.filter {
            force || $0.recoveryReference == nil || $0.recoveryRevision != $0.buffer.revision
        }
        let oldReferences = captured.compactMap(\.recoveryReference)
        guard !changed.isEmpty || oldReferences.count != captured.count || force else {
            return
        }
        let payload: [(RecoveryDocument, PieceTree)] = changed.map {
            var metadata = $0.recoveryDocument()
            metadata.text = ""
            return (metadata, $0.buffer.text)
        }
        let ids = captured.map {
            $0.buffer.id
        }
        let selected = activeID
        let executor = recoveryIO
        recoveryTask = Task {
            [weak self] in
            guard let self else {
                return false
            }
            defer {
                self.recoveryTask = nil
                self.refreshUI()
            }
            do {
                let references = try await executor.run {
                    var references = Dictionary(
                        uniqueKeysWithValues: oldReferences.map {
                            ($0.id, $0)
                        }
                    )
                    for (metadata, tree) in payload {
                        var record = metadata
                        record.text = tree.text()
                        references[record.id] = try store.checkpoint(record)
                    }
                    let ordered = ids.compactMap {
                        references[$0]
                    }
                    try store.publish(ordered, active: selected)
                    return references
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
                    document.recoveryError = nil
                    if document.url == nil {
                        document.state = "恢复内容已保存 · 尚未选择原文件"
                        document.dirtyHint = false
                    }
                }
                return true
            }
            catch {
                for document in captured {
                    document.recoveryError = error.localizedDescription
                }
                self.mainWindow?.status.stringValue = "恢复保存失败：" + error.localizedDescription
                return false
            }
        }
    }

    /// 业务作用：关闭、退出或会话保存前立即确认独立恢复通道。
    /// 参数说明: 无。
    /// 返回：当前工作区索引可靠发布后为真。
    func flushRecovery() async -> Bool {
        if let task = recoveryTask {
            _ = await task.value
        }
        scheduleRecovery(force: true)
        return await recoveryTask?.value ?? false
    }
}
