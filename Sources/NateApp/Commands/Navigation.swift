import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：结果导航复验原快照身份，失效偏移不冒充精确匹配。
    /// 参数说明:
    /// - index: 当前展示结果的条目序号。
    /// 返回：打开对应文档并选中完整命中；过期时保留正文并提示。
    func navigateResult(_ index: Int) {
        guard resultNavigation.indices.contains(index) else {
            return
        }
        let target = resultNavigation[index]
        guard target.documentID != nil || target.url != nil else {
            return
        }
        Task {
            if let id = target.documentID,
                let document = documents.first(where: {
                    $0.buffer.id == id
                })
            {
                guard target.revision == nil || document.buffer.revision == target.revision else {
                    SystemIntegration.alert("结果已过期", "文档在搜索后已改变，请重新搜索后定位。")
                    return
                }
                activate(id)
            }
            else if let url = target.url {
                if let expected = target.diskBaseline {
                    let current = try? await fileIO.run {
                        try FileStorage.baseline(url)
                    }
                    guard current == expected else {
                        SystemIntegration.alert("磁盘结果已过期", "文件在搜索后已经变化，请重新搜索。")
                        return
                    }
                }
                await openFile(url)
                if let expected = target.diskBaseline {
                    active?.evaluateDirty()
                    guard active?.baseline == expected, active?.isDirty == false else {
                        SystemIntegration.alert("结果来自磁盘快照", "当前缓冲区与磁盘快照不同，请重新搜索缓冲区或重新载入后定位。")
                        return
                    }
                }
            }
            guard let active, active.buffer.text.isBoundary(target.range.lower),
                active.buffer.text.isBoundary(target.range.upper)
            else {
                return
            }
            active.buffer.selections = [TextSelection(anchor: target.range.lower, head: target.range.upper)]
            mainWindow?.editor.refresh(reveal: true)
            mainWindow?.window?.makeFirstResponder(mainWindow?.editor)
            refreshUI()
        }
    }

    /// 业务作用：用户主动将选区解释为路径或网址，编辑本身不会发起网络访问。
    /// 参数说明:
    /// - action: 打开文件、Finder 定位或系统网址打开。
    /// 返回：只操作明确选择的目标，未知协议拒绝。
    func openSelection(_ action: String) {
        guard let active, let range = active.buffer.selections.first?.range, !range.isEmpty else {
            return
        }
        let value = active.buffer.text.text(in: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "openURL" {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                SystemIntegration.alert("网址无效", "只支持用户主动打开 http 或 https 网址。")
                return
            }
            NSWorkspace.shared.open(url)
        }
        else {
            let expanded = (value as NSString).expandingTildeInPath
            let url =
                expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : (active.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory()))
                    .appendingPathComponent(expanded)
            if action == "revealSelection" {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            else {
                Task {
                    await openFile(url)
                }
            }
        }
    }

    /// 业务作用：非法或未知编码提供显式重新解释与只读字节查看，不有损覆盖源文件。
    /// 参数说明:
    /// - url: 解码失败的原目标。
    /// - reason: 原始失败原因。
    /// 返回：用户确认后打开所选代码页或独立字节视图。
    func offerDecode(_ url: URL, reason: String) async {
        let alert = NSAlert()
        alert.messageText = "选择 \(url.lastPathComponent) 的编码"
        alert.informativeText = reason + "\n原字节保持不变。编码属于用户选择，不会被标记为已确认的自动识别。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        popup.addItems(withTitles: TextEncoding.available.map(\.name))
        popup.selectItem(at: 5)
        alert.accessoryView = popup
        alert.addButton(withTitle: "按所选编码打开")
        alert.addButton(withTitle: "只读字节查看")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            await openFile(url, explicitEncoding: TextEncoding.available[popup.indexOfSelectedItem])
        }
        else if choice == .alertSecondButtonReturn {
            do {
                let display = try await fileIO.run {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let bytes = [UInt8](data.prefix(4_194_304))
                    var lines: [String] = []
                    for i in stride(from: 0, to: bytes.count, by: 16) {
                        let segment = bytes[i..<min(i + 16, bytes.count)]
                        lines.append(
                            String(format: "%08X  ", i)
                                + segment.map {
                                    String(format: "%02X", $0)
                                }.joined(separator: " ")
                        )
                    }
                    return "文件 \(data.count) 字节。只读显示前 \(bytes.count) 字节；原文件不会作为此视图的保存目标。\n"
                        + lines.joined(separator: "\n")
                }
                let document = WorkspaceDocument(name: url.lastPathComponent + " · 字节视图", text: display)
                document.buffer.isReadOnly = true
                documents.append(document)
                activate(document.buffer.id)
            }
            catch {
                SystemIntegration.alert("无法读取字节", error.localizedDescription)
            }
        }
    }
}
