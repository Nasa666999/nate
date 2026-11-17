import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：编辑器只读同时撤销尚未发布的原文件写入权限，已发布结果仍正常确认。
    /// 参数说明:
    /// - document: 需要改变编辑权限的文档。
    /// - value: 是否只读。
    /// 返回：立即阻止新事务与新保存；解除只读不改变磁盘权限。
    func setReadOnly(_ document: WorkspaceDocument, value: Bool) {
        mainWindow?.editor.finishComposition()
        if value {
            document.savePermit?.cancel()
        }
        document.buffer.isReadOnly = value
        if !value {
            document.monitoring = false
        }
        refreshUI()
    }

    /// 业务作用：进入只读监视前保存当前正文，不能用磁盘更新覆盖尚未保护的本地输入。
    /// 参数说明: 无。
    /// 返回：角色仍有效时进入监视，停止后恢复原只读设置；等待期间目标或权威变化则保持原模式。
    func toggleMonitoring() async {
        guard !closing, let document = active, let target = document.url, !document.closing,
            !document.buffer.isEditingSuspended
        else {
            return
        }
        if document.monitoring {
            document.monitoring = false
            document.state = "监视已停止"
            setReadOnly(document, value: document.readOnlyBeforeMonitoring)
            return
        }
        // 已有路径操作尚未收束时，不能再冻结输入并等待同一目标形成循环等待。
        guard !document.bindingChange else {
            return
        }
        mainWindow?.editor.finishComposition()
        // 固定最终输入后收束写入，监视期间只允许显式磁盘载入改变缓冲区。
        let generation = document.targetGeneration
        document.setEditingSuspension(.monitoringPreparation, active: true)
        defer {
            document.setEditingSuspension(.monitoringPreparation, active: false)
        }
        guard await flush(document) else {
            SystemIntegration.alert("未进入监视", document.failure ?? "当前内容尚未保存，请先处理保存状态。")
            return
        }
        // 等待保存期间可能已经关闭、退出或改变目标，旧监视意图不能取得新路径的角色。
        guard !document.closing, !closing, !document.bindingChange, document.url == target,
            document.targetGeneration == generation,
            documents.contains(where: {
                $0 === document
            })
        else {
            return
        }
        document.readOnlyBeforeMonitoring = document.buffer.isReadOnly
        document.monitoring = true
        document.buffer.isReadOnly = true
        document.state = "监视中 · 等待外部更新"
        document.setEditingSuspension(.monitoringPreparation, active: false)
        await inspectExternalChanges()
        refreshUI()
    }
}
