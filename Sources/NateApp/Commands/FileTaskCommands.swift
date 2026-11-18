import AppKit
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：展示写入任务的真实阶段、耗时和单次发布资格，界面不持有文件权限。
    /// 参数说明: 无。
    /// 返回：复用独立任务窗口，关闭窗口不停止文件动作。
    func showFileTasks() {
        if fileTasksWindow == nil {
            let window = FileTasksWindow()
            window.onRefresh = {
                [weak self] in
                self?.refreshFileTasks()
            }
            window.onCancel = {
                [weak self] id in
                self?.cancelFileTask(id)
            }
            window.onClearCompleted = {
                [weak self] in
                self?.fileOperations.clearCompleted()
            }
            fileTasksWindow = window
        }
        refreshFileTasks()
        fileTasksWindow?.showWindow(nil)
    }

    /// 业务作用：读取轻量任务元数据，不复制正文或抢占当前编辑器焦点。
    /// 参数说明: 无。
    /// 返回：窗口反映全部在途请求及有限完成记录。
    func refreshFileTasks() {
        let channels = [
            ("原文件", fileIO),
            ("读取", readIO),
            ("恢复", recoveryIO),
            ("侧栏恢复", sidebarRecovery.io),
            ("外部命令", commandIO),
        ]
        fileTasksWindow?.updateExecutionStatus(
            channels.map {
                name,
                executor in
                let value = executor.snapshot
                return "\(name)：执行 \(value.running)，超时未返回 \(value.stalled)，排队 \(value.queued)"
                    + (value.quarantined ? "（暂停新请求）" : "")
            }.joined(separator: "；")
        )
        fileTasksWindow?.update(
            fileOperations.snapshots.map {
                operation in
                let end = operation.finished ?? .now
                let elapsed = operation.started.duration(to: end)
                let seconds =
                    Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                var details = "任务：" + operation.id.uuidString
                if let revision = operation.revision {
                    details += " · 正文修订 \(revision)"
                }
                if let generation = operation.targetGeneration {
                    details += " · 目标绑定代次 \(generation)"
                }
                if case .failed(let reason) = operation.result {
                    details += "\n" + reason
                }
                let failed: Bool
                if case .failed = operation.result {
                    failed = true
                }
                else {
                    failed = false
                }
                return FileTaskPresentation(
                    id: operation.id,
                    title: operation.title,
                    target: operation.target.path,
                    stage: fileTaskStage(operation.stage),
                    status: fileTaskStatus(operation),
                    elapsed: String(format: "%.1f 秒", seconds),
                    detail: details,
                    cancellable: operation.canCancel,
                    finished: operation.finished != nil,
                    failed: failed
                )
            }
        )
    }

    /// 业务作用：动作时重新检查任务身份，撤销本次发布后暂缓自动重试以便用户查看状态。
    /// 参数说明:
    /// - id: 用户选中的稳定任务身份。
    /// 返回：尚未发布的请求失去发布权，实际系统返回前继续留在任务表中。
    func cancelFileTask(_ id: UUID) {
        guard
            let operation = fileOperations.snapshots.first(where: {
                $0.id == id
            }), operation.canCancel
        else {
            return
        }
        fileOperations.cancel(id)
        if let document = documents.first(where: {
            $0.buffer.id == operation.documentID
        }) {
            document.nextRetry = .now.advanced(by: .seconds(30))
        }
        refreshFileTasks()
        refreshUI()
    }

    /// 业务作用：把实际存储阶段映射为用户可判断的文件动作。
    /// 参数说明:
    /// - stage: 存储入口已实际进入的阶段。
    /// 返回：不把等待、发布和确认混作同一种保存状态。
    func fileTaskStage(_ stage: FileSaveStage) -> String {
        switch stage {
        case .queued: return "等待后台线程"
        case .preparingBytes: return "准备编码字节"
        case .waitingForAccess: return "等待系统文件访问"
        case .checkingBaseline: return "核对原文件"
        case .preservingBackup: return "保护覆盖前的原始字节"
        case .preparingDirectory: return "取得目标目录同步权限"
        case .writingTemporary: return "写入临时文件"
        case .preservingMetadata: return "保留文件权限与属性"
        case .synchronizingFile: return "同步文件内容"
        case .revalidatingBaseline: return "复验目标身份"
        case .publishing: return "发布到目标路径"
        case .published: return "目标已替换"
        case .synchronizingDirectory: return "同步目录"
        case .confirmingSavedFile: return "确认保存后字节"
        }
    }

    /// 业务作用：区分取消意图、未决发布和实际返回，不把超时当成底层系统已经结束。
    /// 参数说明:
    /// - operation: 同次锁定读取的任务状态。
    /// 返回：当前完成、失败或等待语义。
    func fileTaskStatus(_ operation: FileOperationSnapshot) -> String {
        switch operation.result {
        case .succeeded: return operation.stage == .confirmingSavedFile ? "已完成并确认" : "已完成"
        case .cancelled: return "已取消并结束"
        case .failed: return operation.requiresReconciliation ? "未确认 · 需核验目标" : "失败 · 正文保留"
        case .running:
            if operation.hasActivePublication {
                return "发布执行中 · 等待系统返回"
            }
            if operation.publication == .completed {
                return "已发布 · 等待确认"
            }
            return operation.permissionRevoked ? "发布权已撤销 · 等待系统返回" : "进行中"
        }
    }
}
