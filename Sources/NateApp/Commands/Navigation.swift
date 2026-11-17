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
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        resultNavigationGeneration = UUID()
        // 退出已固定活动文档与恢复视图，迟到导航不能在最终确认期间切换这份状态。
        guard !closing, mainWindow != nil else {
            return
        }
        guard resultNavigation.indices.contains(index) else {
            return
        }
        let target = resultNavigation[index]
        guard target.documentID != nil || target.url != nil else {
            return
        }
        mainWindow?.editor.finishComposition()
        let request = resultNavigationGeneration
        let query = queryGeneration
        let selectionGeneration = searchNavigationGeneration
        let revision = active?.buffer.revision
        let selections = mainWindow?.editor.viewSelections
        let documentSelections = active?.buffer.selections
        let presentation = mainWindow?.resultGeneration
        // 请求绑定原窗口和原光标证据；系统读取期间用户改选区、换视图或换结果后不能继续取得焦点。
        let permitted: @MainActor () -> Bool = {
            [weak self, weak origin = active?.buffer, weak editor = mainWindow?.editor] in
            guard let self, !self.closing, !Task.isCancelled,
                self.resultNavigationGeneration == request, self.queryGeneration == query,
                self.searchNavigationGeneration == selectionGeneration,
                self.mainWindow?.resultGeneration == presentation,
                self.active?.buffer === origin, self.mainWindow?.editor === editor,
                origin?.revision == revision, editor?.viewSelections == selections,
                origin?.selections == documentSelections, editor?.hasMarkedText() != true
            else {
                return false
            }
            return true
        }
        resultNavigationTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if request == self.resultNavigationGeneration {
                    self.resultNavigationTask = nil
                }
            }
            guard permitted() else {
                return
            }
            let destination: WorkspaceDocument
            if let id = target.documentID {
                // 稳定 UUID 可能来自恢复重开，只有生成结果时的真实文档对象仍在工作区才可使用原偏移。
                guard
                    let document = self.documents.first(where: {
                        candidate in
                        candidate.buffer.id == id
                    }),
                    target.authority?.matches(document) == true,
                    target.revision == document.buffer.revision
                else {
                    self.mainWindow?.status.stringValue = "结果已过期：原文档已关闭、重开或改变，请重新搜索。"
                    return
                }
                destination = document
            }
            else if let url = target.url {
                if let expected = target.diskBaseline {
                    let current = try? await self.readIO.readCancellable {
                        token in
                        try self.fileAccess.baseline(
                            url,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                    guard permitted() else {
                        return
                    }
                    guard current == expected else {
                        self.mainWindow?.status.stringValue = "磁盘结果已过期：文件在搜索后已经变化，请重新搜索。"
                        return
                    }
                }
                guard let document = await self.openFile(url, activateOnOpen: false, permit: permitted),
                    permitted()
                else {
                    return
                }
                if let expected = target.diskBaseline {
                    document.evaluateDirty()
                    guard document.baseline == expected, !document.isDirty,
                        target.diskEncoding == nil || document.encoding == target.diskEncoding
                    else {
                        self.mainWindow?.status.stringValue = "文件编码或正文与搜索时不同，请重新搜索当前缓冲区。"
                        return
                    }
                }
                destination = document
            }
            else {
                return
            }
            // 等待期间出现的新预编辑属于用户的新输入，不能由迟到导航主动提交或丢弃。
            guard permitted() else {
                return
            }
            guard destination.buffer.text.isBoundary(target.range.lower),
                destination.buffer.text.isBoundary(target.range.upper)
            else {
                self.mainWindow?.status.stringValue = "结果范围无法无损定位，请重新搜索。"
                return
            }
            // 全部异步证据复验完毕后在同一执行域内激活并发布选区，不再跨越可重入边界。
            self.activate(destination.buffer.id)
            destination.buffer.selections = [
                TextSelection(
                    anchor: target.range.lower,
                    head: target.range.upper
                )
            ]
            self.mainWindow?.editor.refresh(reveal: true)
            self.mainWindow?.window?.makeFirstResponder(self.mainWindow?.editor)
            self.refreshUI()
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
                let display = try await readIO.readCancellable {
                    token in
                    let sample = try self.fileAccess.withRead(
                        at: url,
                        permit: {
                            !token.isCancelled
                        }
                    ) {
                        target in
                        try FileStorage.readSample(
                            target,
                            maximumBytes: 4_194_304,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                    let bytes = [UInt8](sample.data)
                    var lines: [String] = []
                    for i in stride(from: 0, to: bytes.count, by: 16) {
                        try token.check()
                        let segment = bytes[i..<min(i + 16, bytes.count)]
                        lines.append(
                            String(format: "%08X  ", i)
                                + segment.map {
                                    String(format: "%02X", $0)
                                }.joined(separator: " ")
                        )
                    }
                    return "文件 \(sample.totalByteCount) 字节。只读显示前 \(bytes.count) 字节；原文件不会作为此视图的保存目标。\n"
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
