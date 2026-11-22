import AppKit
import NateCore
import NatePlatform

struct PreparedDocumentExport: Sendable {
    let documentID: UUID
    let revision: UInt64
    let name: String
    let data: Data
}

extension ApplicationController {
    /// 业务作用：所有富文本导出入口共用真实来源和输入保护，打开面板不能间接确认未提交的候选。
    /// 参数说明: 无。
    /// 返回：当前主视图绑定有效且没有候选、关闭或编辑暂停时允许准备；只读正文仍可独立导出。
    var canPrepareDocumentExport: Bool {
        guard !closing, !choosingDocumentExport, let document = active, let window = mainWindow,
            window.editor.document === document.buffer, !document.closing,
            !document.buffer.isEditingSuspended, !window.hasMarkedEditorInput,
            findWindow?.isEditingInput != true
        else {
            return false
        }
        return true
    }

    /// 业务作用：先固定完整正文、语言字体与编码后的导出内容，再允许保存面板转移焦点。
    /// 参数说明:
    /// - html: 为真时生成 HTML，否则生成 RTF。
    /// 返回：与开始时文档身份和修订一致的独立字节；候选、容量或样式失败不打开目标面板。
    func prepareCurrentDocumentExport(html: Bool) throws -> PreparedDocumentExport {
        guard canPrepareDocumentExport, let document = active, let window = mainWindow else {
            throw NateError.message("导出需要有效正文；请先确认或取消输入法候选，并等候当前文档保护完成。")
        }
        let editor = window.editor
        choosingDocumentExport = true
        defer {
            choosingDocumentExport = false
        }
        let snapshot = document.buffer.snapshot
        let name = document.name + (html ? ".html" : ".rtf")
        let styled = try styledSnapshot(document, snapshot: snapshot)
        let data = try styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [
                .documentType: html ? NSAttributedString.DocumentType.html : .rtf,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
        try Task.checkCancellation()
        // 系统富文本编码可能处理嵌套事件；弹出目标面板前仍须保有原来源，不能借准备过程确认后来候选。
        guard !closing, active === document, mainWindow === window,
            editor.document === document.buffer, !document.closing,
            !document.buffer.isEditingSuspended, !window.hasMarkedEditorInput,
            findWindow?.isEditingInput != true
        else {
            throw NateError.message("导出准备期间来源或输入保护已改变，未打开目标面板。")
        }
        guard data.count <= 256 * 1024 * 1024 else {
            throw NateError.message("完整富文本导出超过 256 MiB，未打开目标面板。")
        }
        return PreparedDocumentExport(
            documentID: snapshot.id,
            revision: snapshot.revision,
            name: name,
            data: data
        )
    }

    /// 业务作用：HTML/RTF 导出保留开始时的正文与样式，成功不改变原文件关联、保存点或撤销。
    /// 参数说明:
    /// - html: 是否导出 HTML，否则 RTF。
    /// 返回：完整准备后选择独立目标并启动受登记的原子写入；取消不发布文件。
    func exportDocument(html: Bool) {
        guard canPrepareDocumentExport else {
            mainWindow?.status.stringValue = "请先确认或取消输入法候选，并等候当前文档保护或导出面板完成。"
            return
        }
        do {
            let prepared = try prepareCurrentDocumentExport(html: html)
            choosingDocumentExport = true
            defer {
                choosingDocumentExport = false
            }
            guard
                let url = SystemIntegration.chooseSave(name: prepared.name, directory: fileDialogDirectory())
            else {
                return
            }
            Task {
                do {
                    try await publishDocumentExport(prepared, to: url)
                    if !closing {
                        mainWindow?.status.stringValue = "富文本已导出 · " + url.lastPathComponent
                    }
                }
                catch is CancellationError {
                    if !closing {
                        mainWindow?.status.stringValue = "导出已取消，原文档和保存点保持原状。"
                    }
                }
                catch {
                    if !closing {
                        mainWindow?.status.stringValue = "导出未确认：" + error.localizedDescription
                    }
                }
            }
        }
        catch {
            mainWindow?.status.stringValue = "导出未开始：" + error.localizedDescription
        }
    }
}
