import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：所有打开入口按真实文件身份去重，避免竞争自动保存。
    /// 参数说明:
    /// - url: Finder、对话框或 CLI 提供的路径。
    /// - explicitEncoding: 用户选择的重新解释代码页。
    /// 返回：实际打开的文档；失败返回空，不误用先前的活动标签。
    @discardableResult
    func openFile(_ url: URL, explicitEncoding: TextEncoding? = nil) async -> WorkspaceDocument? {
        guard !closing else {
            return nil
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            await showFolder(url)
            return nil
        }
        let catalog = codecs
        mainWindow?.status.stringValue = "正在读取 · " + url.lastPathComponent + " · 可在工具菜单取消读取"
        do {
            let loaded = try await readIO.readCancellable {
                token in
                try self.fileAccess.load(
                    url,
                    encoding: explicitEncoding,
                    catalog: catalog,
                    permit: {
                        !token.isCancelled
                    }
                )
            }
            // 退出开始后不再发布迟到的新标签，原文件并未被打开动作修改。
            guard !closing else {
                return nil
            }
            if let existing = documents.first(where: {
                ($0.baseline?.device == loaded.baseline.device && $0.baseline?.inode == loaded.baseline.inode)
                    || $0.baseline?.resolvedPath == loaded.baseline.resolvedPath
                    || $0.url?.standardizedFileURL == loaded.url.standardizedFileURL
            }) {
                activate(existing.buffer.id)
                return existing
            }
            // 保存或批量替换还未发布绑定时，不能从旧磁盘快照建立另一个写入者。
            guard targetReservations[loaded.baseline.resolvedPath] == nil else {
                throw NateError.message("该目标正在完成文件操作，请稍后重新打开。")
            }
            let document = WorkspaceDocument(
                name: url.lastPathComponent,
                text: loaded.text,
                textTree: loaded.tree,
                encoding: loaded.encoding,
                lineEnding: loaded.lineEnding
            )
            document.url = loaded.url
            document.baseline = loaded.baseline
            document.savedEncoding = loaded.encoding
            document.state = loaded.inferred ? "已载入 · 编码为推断，可重新解释" : "已载入"
            document.language =
                registry?.detect(
                    filename: url.lastPathComponent,
                    firstLine: String(loaded.text.prefix(4096)).split(whereSeparator: \.isNewline).first.map(
                        String.init
                    ) ?? ""
                ) ?? "normal"
            documents.append(document)
            recentFiles =
                [url.path]
                + recentFiles.filter {
                    $0 != url.path
                }
            activate(document.buffer.id)
            buildMenus()
            return document
        }
        catch is CancellationError {
            return nil
        }
        catch is ReadDeadlineExceeded {
            mainWindow?.showResults("读取未完成：" + url.path + "\n" + ReadDeadlineExceeded().localizedDescription)
        }
        catch let error as FileDecodingFailure {
            if explicitEncoding == nil {
                await offerDecode(url, reason: error.localizedDescription)
            }
            else {
                SystemIntegration.alert("无法打开 \(url.lastPathComponent)", error.localizedDescription)
            }
        }
        catch {
            SystemIntegration.alert("无法打开 \(url.lastPathComponent)", error.localizedDescription)
        }
        return nil
    }

    /// 业务作用：另存为先完成新目标持久化，再发布路径和保存点；副本保留原绑定。
    /// 参数说明:
    /// - document: 当前文档。
    /// - copy: 是否仅保存副本。
    /// 返回：成功后更新相应状态；失败保留旧关联。
    func saveAs(_ document: WorkspaceDocument, copy: Bool = false) async {
        guard !document.bindingChange else {
            return
        }
        // 目标切换先关闭旧通道入口，再等待已经开始的快照收束。
        document.bindingChange = true
        defer {
            document.bindingChange = false
        }
        let catalog = codecs
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
        if document.buffer.isReadOnly
            && document.url?.resolvingSymlinksInPath().standardizedFileURL == resolved
        {
            SystemIntegration.alert("原目标为编辑器只读", "请选择不同的另存为目标，或先明确解除编辑器只读。")
            return
        }
        let owner = UUID()
        guard reserveTarget(resolved.path, owner: owner) else {
            SystemIntegration.alert("目标正在使用", "另一个文件动作尚未完成，请稍后重试。")
            return
        }
        defer {
            releaseTarget(resolved.path, owner: owner)
        }
        // 只读切换撤销尚未发布的显式保存，替换已完成时仍确认实际保存点。
        let permit = CancellationToken()
        document.savePermit = permit
        defer {
            if document.savePermit === permit {
                document.savePermit = nil
            }
        }
        do {
            let result = try await fileIO.run {
                let expected =
                    FileManager.default.fileExists(atPath: destination.path)
                    ? try self.fileAccess.baseline(destination) : nil
                let data = try encoding.encode(snapshot.text.text(), catalog: catalog)
                return try self.fileAccess.save(
                    data,
                    to: destination,
                    expected: expected,
                    replacing: true,
                    permit: {
                        !permit.isCancelled
                    }
                )
            }
            if !copy {
                document.targetGeneration += 1
                document.url = destination
                document.originalBindingTask?.cancel()
                document.originalBindingRequest = UUID()
                document.pendingOriginalPath = nil
                document.pendingOriginalBaseline = nil
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
        catch is CancellationError {
            mainWindow?.status.stringValue = "保存请求已取消，当前正文与原关联保持可用。"
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
        guard !document.bindingChange else {
            return
        }
        document.bindingChange = true
        defer {
            document.bindingChange = false
        }
        let catalog = codecs
        guard let url = document.url else {
            return
        }
        let snapshot = document.buffer.snapshot
        let monitoring = document.monitoring
        if let task = document.saveTask {
            _ = await task.value
        }
        guard await flushRecovery() else {
            return
        }
        do {
            let (loaded, prepared) = try await readIO.readCancellable {
                token in
                let loaded = try self.fileAccess.load(
                    url,
                    encoding: encoding,
                    catalog: catalog,
                    permit: {
                        !token.isCancelled
                    }
                )
                let format = DocumentFormat(
                    codePage: loaded.encoding.codePage,
                    bom: loaded.encoding.bom,
                    lineEnding: loaded.lineEnding
                )
                let prepared = try PreparedTransaction(
                    replacing: snapshot,
                    with: loaded.tree,
                    selectionsAfter: monitoring ? nil : [TextSelection(anchor: 0, head: 0)],
                    formatAfter: format,
                    name: "重新载入"
                )
                return (loaded, prepared)
            }
            // 停止监视或开始关闭后，旧读取结果不得继续发布到缓冲区。
            guard !closing, !document.closing, !monitoring || document.monitoring else {
                return
            }
            let readOnly = document.buffer.isReadOnly
            document.buffer.isReadOnly = false
            defer {
                document.buffer.isReadOnly = readOnly
            }
            try document.buffer.commit(prepared)
            document.buffer.isReadOnly = readOnly
            document.baseline = loaded.baseline
            document.savedEncoding = loaded.encoding
            document.savedText = document.buffer.text
            document.dirtyHint = false
            document.conflict = false
            document.failure = nil
            document.state = monitoring ? "监视中 · 已刷新" : "已重新载入"
            mainWindow?.refreshEditors()
            if monitoring && document.buffer.selections.first?.head == document.buffer.text.byteCount
                && mainWindow?.editor.document.id == document.buffer.id
            {
                mainWindow?.editor.revealSelection()
            }
            refreshUI()
        }
        catch is CancellationError {
            return
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
        guard !document.closing else {
            return
        }
        if activeID == id {
            mainWindow?.editor.finishComposition()
        }
        document.closing = true
        document.originalBindingTask?.cancel()
        document.buffer.isEditingSuspended = true
        defer {
            document.closing = false
            document.buffer.isEditingSuspended = false
        }
        var archiveNeeded = document.url == nil && document.buffer.text.byteCount > 0
        if archiveNeeded {
            let alert = NSAlert()
            alert.messageText = "关闭临时文档 \(document.name)"
            alert.informativeText = "可以保存到文件，或保留独立恢复副本后关闭。最近 100 份关闭内容可从文件菜单恢复。"
            alert.addButton(withTitle: "另存为")
            alert.addButton(withTitle: "保留恢复副本并关闭")
            alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                await saveAs(document)
                guard document.url != nil else {
                    return
                }
                archiveNeeded = false
            }
            else if choice != .alertSecondButtonReturn {
                return
            }
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
            archiveNeeded = true
        }
        if archiveNeeded {
            guard await flushRecovery(), let reference = document.recoveryReference, let store = recovery
            else {
                return
            }
            do {
                try await recoveryIO.run {
                    try store.archive(reference)
                }
            }
            catch {
                SystemIntegration.alert("关闭未完成", error.localizedDescription)
                return
            }
        }
        let oldIndex =
            documents.firstIndex(where: {
                $0 === document
            }) ?? 0
        documents.removeAll {
            $0 === document
        }
        if activeID == id {
            activeID = documents.first?.buffer.id
        }
        guard await flushRecovery() else {
            documents.insert(document, at: min(oldIndex, documents.count))
            activate(id)
            SystemIntegration.alert("关闭未完成", "打开文档索引未能可靠更新，内容保持打开。")
            return
        }
        recentClosed.append(
            ClosedTab(
                url: archiveNeeded ? nil : document.url,
                recovery: archiveNeeded ? document.recoveryReference : nil,
                name: document.name
            )
        )
        mainWindow?.retireDocument(id)
        externalStamps.removeValue(forKey: id)
        if recentClosed.count > 20 {
            recentClosed.removeFirst()
        }
        if documents.isEmpty {
            _ = newDocument()
        }
        else if let activeID {
            activate(activeID)
        }
        refreshUI()
    }
}
