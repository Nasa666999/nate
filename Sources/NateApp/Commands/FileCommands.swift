import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：所有打开入口按真实文件身份去重，避免竞争自动保存。
    /// 参数说明:
    /// - url: Finder、对话框或 CLI 提供的路径。
    /// - explicitEncoding: 用户选择的重新解释代码页。
    /// 返回：完整读取后发布标签，失败不创建空文档冒充内容。
    func openFile(_ url: URL, explicitEncoding: TextEncoding? = nil) async {
        do {
            let loaded = try await fileIO.run {
                try FileStorage.load(url, encoding: explicitEncoding)
            }
            if let existing = documents.first(where: {
                $0.baseline?.device == loaded.baseline.device && $0.baseline?.inode == loaded.baseline.inode
            }) {
                activate(existing.buffer.id)
                return
            }
            let document = WorkspaceDocument(name: url.lastPathComponent, text: loaded.text)
            document.url = loaded.url
            document.baseline = loaded.baseline
            document.encoding = loaded.encoding
            document.savedEncoding = loaded.encoding
            document.state = loaded.inferred ? "已载入 · 编码为推断，可重新解释" : "已载入"
            document.language =
                registry?.detect(
                    filename: url.lastPathComponent,
                    firstLine: loaded.text.components(separatedBy: .newlines).first ?? ""
                ) ?? "normal"
            documents.append(document)
            recentFiles =
                [url.path]
                + recentFiles.filter {
                    $0 != url.path
                }
            activate(document.buffer.id)
            buildMenus()
        }
        catch {
            SystemIntegration.alert("无法打开 \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    /// 业务作用：另存为先完成新目标持久化，再发布路径和保存点；副本保留原绑定。
    /// 参数说明:
    /// - document: 当前文档。
    /// - copy: 是否仅保存副本。
    /// 返回：成功后更新相应状态；失败保留旧关联。
    func saveAs(_ document: WorkspaceDocument, copy: Bool = false) async {
        mainWindow?.editor.finishComposition()
        if let task = document.saveTask {
            _ = await task.value
        }
        guard let destination = SystemIntegration.chooseSave(name: document.name) else {
            return
        }
        let snapshot = document.buffer.snapshot
        let encoding = document.encoding
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        if documents.contains(where: {
            $0 !== document && $0.url?.resolvingSymlinksInPath().standardizedFileURL == resolved
        }) {
            SystemIntegration.alert("目标已打开", "请切换到该目标文档，不能为同一文件建立第二个写入者。")
            return
        }
        if copy && document.url?.resolvingSymlinksInPath().standardizedFileURL == resolved {
            SystemIntegration.alert("副本目标无效", "副本不能与原文件指向同一目标。")
            return
        }
        do {
            let result = try await fileIO.run {
                let expected =
                    FileManager.default.fileExists(atPath: destination.path)
                    ? try FileStorage.baseline(destination) : nil
                let data = try encoding.encode(snapshot.text.text())
                return try FileStorage.save(data, to: destination, expected: expected)
            }
            if !copy {
                document.targetGeneration += 1
                document.url = destination
                document.name = destination.lastPathComponent
                document.baseline = result
                document.savedText = snapshot.text
                document.savedEncoding = encoding
                document.lastSavedRevision = snapshot.revision
                document.failure = nil
                document.conflict = false
                document.evaluateDirty()
                document.state = "已保存"
                if !document.languageExplicit {
                    document.language =
                        registry?.detect(
                            filename: destination.lastPathComponent,
                            firstLine: snapshot.text.text(in: snapshot.text.lineRange(0))
                        ) ?? "normal"
                }
                recentFiles =
                    [destination.path]
                    + recentFiles.filter {
                        $0 != destination.path
                    }
            }
            refreshUI()
            _ = await flushRecovery()
        }
        catch {
            SystemIntegration.alert("保存失败", error.localizedDescription)
        }
    }

    /// 业务作用：重新载入前保留独立恢复内容，再以可撤销事务替换正文。
    /// 参数说明:
    /// - document: 待重新载入文档。
    /// - encoding: 重新解释代码页，为空时按文件证据识别。
    /// 返回：旧正文仍可撤销；基线只取新读取内容。
    func reload(_ document: WorkspaceDocument, encoding: TextEncoding? = nil) async {
        guard let url = document.url else {
            return
        }
        if let task = document.saveTask {
            _ = await task.value
        }
        guard await flushRecovery() else {
            return
        }
        do {
            let loaded = try await fileIO.run {
                try FileStorage.load(url, encoding: encoding)
            }
            let readOnly = document.buffer.isReadOnly
            document.buffer.isReadOnly = false
            defer {
                document.buffer.isReadOnly = readOnly
            }
            try document.buffer.commit(
                [TextEdit(ByteRange(0, document.buffer.text.byteCount), loaded.text)],
                selectionsAfter: [TextSelection(anchor: 0, head: 0)],
                name: "重新载入"
            )
            document.baseline = loaded.baseline
            document.encoding = loaded.encoding
            document.savedEncoding = loaded.encoding
            document.savedText = document.buffer.text
            document.dirtyHint = false
            document.conflict = false
            document.failure = nil
            mainWindow?.editor.refresh()
            refreshUI()
        }
        catch {
            SystemIntegration.alert("无法重新载入", error.localizedDescription)
        }
    }

    /// 业务作用：关闭最后视图前完成保存或可靠恢复，不销毁未保护内容。
    /// 参数说明:
    /// - id: 被关闭文档身份。
    /// 返回：确认保护后从工作区移除并可靠更新恢复索引。
    func closeDocument(_ id: UUID) async {
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        if activeID == id {
            mainWindow?.editor.finishComposition()
        }
        let saved = await flush(document)
        if !saved {
            let alert = NSAlert()
            alert.messageText = "尚未保存到原文件"
            alert.informativeText = document.failure ?? "恢复内容尚未可靠保存。"
            alert.addButton(withTitle: "取消关闭")
            alert.addButton(withTitle: "另存为")
            alert.addButton(withTitle: "保留恢复副本并关闭")
            let choice = alert.runModal()
            if choice == .alertSecondButtonReturn {
                await saveAs(document)
                return
            }
            guard choice == .alertThirdButtonReturn, await flushRecovery() else {
                return
            }
            document.url = nil
            document.name += "（恢复副本）"
            activate(id)
            return
        }
        let oldIndex =
            documents.firstIndex(where: {
                $0 === document
            }) ?? 0
        recentClosed.append(document)
        if recentClosed.count > 20 {
            recentClosed.removeFirst()
        }
        documents.removeAll {
            $0 === document
        }
        if documents.isEmpty {
            _ = newDocument()
        }
        if activeID == id {
            activate(documents[min(oldIndex, documents.count - 1)].buffer.id)
        }
        _ = await flushRecovery()
        refreshUI()
    }
}
