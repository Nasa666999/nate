import AppKit
import NateCore
import NatePlatform
import NateStorage

struct ClosedTab {
    var url: URL?
    var recovery: RecoveryReference?
    var name: String
}

extension ApplicationController {
    /// 业务作用：重新打开创建新生命周期，旧任务和历史不冒用同一路径的新文档。
    /// 参数说明: 无。
    /// 返回：已命名文件重新读取，临时内容从校验后的恢复记录载入。
    func reopenClosed() async {
        guard let record = recentClosed.popLast() else {
            return
        }
        if let url = record.url {
            await openFile(url)
        }
        else if let reference = record.recovery {
            await openArchived(reference)
        }
    }

    /// 业务作用：用户明确选择后才载入已关闭的恢复正文，避免长期保留大文档内存。
    /// 参数说明:
    /// - reference: 已选中的完整快照引用。
    /// 返回：独立临时文档，不自动覆盖历史原路径。
    func openArchived(_ reference: RecoveryReference) async {
        guard let store = recovery else {
            return
        }
        do {
            let (record, tree) = try await recoveryIO.read {
                let recovered = try store.loadArchivedSnapshot(reference)
                return (recovered.metadata, recovered.text)
            }
            guard !closing else {
                return
            }
            let document = WorkspaceDocument(
                name: record.name,
                text: record.text,
                textTree: tree,
                encoding: record.encoding,
                lineEnding: record.lineEnding ?? .lf
            )
            document.language = record.language
            document.pinned = record.pinned ?? false
            document.languageExplicit = true
            try document.restoreSelections(from: record)
            document.buffer.bookmarks = record.bookmarks
            documents.append(document)
            activate(document.buffer.id)
        }
        catch {
            SystemIntegration.alert("无法恢复关闭内容", error.localizedDescription)
        }
    }

    /// 业务作用：仅列出轻量保留清单，选择后读取对应的一份正文。
    /// 参数说明: 无。
    /// 返回：恢复窗口可选择最近 100 份明确保留的关闭内容。
    func showRecoveryArchive() async {
        guard let store = recovery else {
            return
        }
        do {
            let references = try await recoveryIO.read {
                try store.archivedReferences()
            }
            guard !references.isEmpty else {
                SystemIntegration.alert("恢复关闭内容", "没有保留的关闭内容。 ")
                return
            }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            popup.addItems(
                withTitles: references.map {
                    $0.name ?? $0.id.uuidString
                }
            )
            let alert = NSAlert()
            alert.messageText = "恢复已关闭内容"
            alert.informativeText = "恢复为独立临时文档，原路径不会被自动覆盖。"
            alert.accessoryView = popup
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                await openArchived(references[popup.indexOfSelectedItem])
            }
        }
        catch {
            SystemIntegration.alert("恢复清单不可用", error.localizedDescription)
        }
    }
}
