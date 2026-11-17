import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：跳过会话恢复时保留的工作区可显式导入，不自动恢复其原路径写入权。
    /// 参数说明: 无。
    /// 返回：完整校验后追加独立临时文档，原工作区和原文件均保留。
    func showPausedWorkspaces() async {
        guard let support = applicationSupport else {
            return
        }
        do {
            let choices = try await recoveryIO.read {
                try FileManager.default.contentsOfDirectory(
                    at: support,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                .filter {
                    let name = $0.lastPathComponent
                    let properties = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return name.hasPrefix("Recovery-paused-")
                        && UUID(uuidString: String(name.dropFirst("Recovery-paused-".count))) != nil
                        && properties.isDirectory == true && properties.isSymbolicLink != true
                }.sorted {
                    $0.lastPathComponent < $1.lastPathComponent
                }
            }
            guard !choices.isEmpty else {
                SystemIntegration.alert("保留工作区", "没有因跳过恢复而保留的先前工作区。")
                return
            }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            popup.addItems(withTitles: choices.map(\.lastPathComponent))
            let alert = NSAlert()
            alert.messageText = "恢复先前保留工作区"
            alert.informativeText = "全部内容作为独立临时文档加入。原文件不会被自动覆盖，原恢复记录继续保留。"
            alert.accessoryView = popup
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let chosen = choices[popup.indexOfSelectedItem]
            let restored = try await recoveryIO.read {
                let result = try RecoveryStore(directory: chosen).restoreSnapshots()
                return result.documents.map {
                    (record: $0.metadata, tree: $0.text)
                }
            }
            guard !closing else {
                return
            }
            for (record, tree) in restored {
                let document = WorkspaceDocument(
                    name: record.name + "（保留工作区）",
                    text: record.text,
                    textTree: tree,
                    encoding: record.encoding,
                    lineEnding: record.lineEnding ?? .lf
                )
                document.language = record.language
                document.pinned = record.pinned ?? false
                document.languageExplicit = true
                document.buffer.bookmarks = record.bookmarks
                document.buffer.selections = record.selections.filter {
                    document.buffer.text.isBoundary($0.anchor) && document.buffer.text.isBoundary($0.head)
                }
                if document.buffer.selections.isEmpty {
                    document.buffer.selections = [TextSelection(anchor: 0, head: 0)]
                }
                documents.append(document)
                activate(document.buffer.id)
            }
            _ = await flushRecovery()
        }
        catch {
            SystemIntegration.alert("保留工作区不可用", error.localizedDescription)
        }
    }
}
