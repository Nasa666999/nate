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
    /// 返回：成功进入持续外部观察；退出恢复原编辑器只读设置。
    func toggleMonitoring() async {
        guard let document = active, document.url != nil, !document.closing,
            !document.buffer.isEditingSuspended
        else {
            return
        }
        if document.monitoring {
            document.monitoring = false
            setReadOnly(document, value: document.readOnlyBeforeMonitoring)
            return
        }
        mainWindow?.editor.finishComposition()
        // 固定最终输入后收束写入，监视期间只允许显式磁盘载入改变缓冲区。
        document.buffer.isEditingSuspended = true
        defer {
            if !document.closing && !closing {
                document.buffer.isEditingSuspended = false
            }
        }
        guard await flush(document) else {
            SystemIntegration.alert("未进入监视", document.failure ?? "当前内容尚未保存，请先处理保存状态。")
            return
        }
        document.readOnlyBeforeMonitoring = document.buffer.isReadOnly
        document.monitoring = true
        document.buffer.isReadOnly = true
        guard !document.closing && !closing else {
            return
        }
        document.buffer.isEditingSuspended = false
        await inspectExternalChanges()
        refreshUI()
    }
}
