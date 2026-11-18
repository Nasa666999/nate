import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：所有打开入口先验证文件 URL，再按真实身份去重，避免错误路径访问和竞争自动保存。
    /// 参数说明:
    /// - url: Finder、对话框或 CLI 提供的路径。
    /// - explicitEncoding: 用户选择的重新解释代码页。
    /// - activateOnOpen: 是否在读取完成后立即激活；异步结果导航可先建立后台标签再复验自己的焦点权限。
    /// - permit: 主执行域中的发布权限，失效时不添加标签、改变焦点或发布迟到错误。
    /// 返回：实际打开的文档；无效 URL 在类型探测前拒绝，失败返回空，不误用先前活动标签。
    @discardableResult
    func openFile(
        _ url: URL,
        explicitEncoding: TextEncoding? = nil,
        activateOnOpen: Bool = true,
        permit: @MainActor () -> Bool = {
            true
        }
    ) async -> WorkspaceDocument? {
        // 打开请求的调用权也可能被后来的导航撤销，读取前不能先改变原视图。
        guard !closing, !Task.isCancelled, permit() else {
            return nil
        }
        let catalog = codecs
        do {
            // 文件类型探测也会访问目标，必须先验证原始 URL，不能先查询被转义成另一名称的路径。
            try FileStorage.validateFileURL(url)
            mainWindow?.status.stringValue = "正在读取 · " + url.lastPathComponent + " · 可在工具菜单取消读取"
            // 类型探测也可能等待外置盘或系统授权，必须使用有界读取通道而不阻塞主事件循环。
            let directory = try await readIO.readCancellable {
                token in
                try token.check()
                let value = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                try token.check()
                return value
            }
            // 类型证据返回时原导航可能已经撤销，目录和文件都先复验调用权再进入后续流程。
            guard !closing, !Task.isCancelled, permit() else {
                return nil
            }
            if directory {
                if activateOnOpen {
                    await showFolder(url)
                }
                return nil
            }
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
            // 系统读取完成不代表原调用仍有发布权，失效请求不得添加标签或切换活动文档。
            guard !closing, !Task.isCancelled, permit() else {
                return nil
            }
            if let existing = documents.first(where: {
                ($0.baseline?.device == loaded.baseline.device && $0.baseline?.inode == loaded.baseline.inode)
                    || $0.baseline?.resolvedPath == loaded.baseline.resolvedPath
                    || $0.url?.standardizedFileURL == loaded.url.standardizedFileURL
            }) {
                if activateOnOpen {
                    activate(existing.buffer.id)
                }
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
            if activateOnOpen {
                activate(document.buffer.id)
            }
            else {
                refreshUI()
            }
            buildMenus()
            return document
        }
        catch {
            if error is CancellationError {
                return nil
            }
            // 迟到错误同样需要原调用权，不能用旧读取的提示覆盖新窗口或新查询。
            guard !closing, !Task.isCancelled, permit() else {
                return nil
            }
            if !activateOnOpen {
                mainWindow?.status.stringValue = "无法打开结果文件：" + error.localizedDescription
                return nil
            }
            if error is ReadDeadlineExceeded {
                mainWindow?.showResults("读取未完成：" + url.path + "\n" + error.localizedDescription)
            }
            else if error is FileDecodingFailure, explicitEncoding == nil {
                await offerDecode(url, reason: error.localizedDescription)
            }
            else {
                SystemIntegration.alert("无法打开 \(url.lastPathComponent)", error.localizedDescription)
            }
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
        guard await waitForOriginalSave(document) else {
            return
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
        let request = fileOperations.begin(
            title: copy ? "保存副本" : "另存为",
            target: destination,
            documentID: snapshot.id,
            revision: snapshot.revision,
            targetGeneration: document.targetGeneration,
            permission: permit
        )
        document.savePermit = permit
        document.saveOperation = request
        defer {
            if document.savePermit === permit {
                document.savePermit = nil
            }
            if document.saveOperation?.id == request.id {
                document.saveOperation = nil
            }
        }
        do {
            let backup = try saveBackupRequest(request)
            let result = try await fileIO.run {
                try self.fileOperations.perform(request) {
                    request.observe(.checkingBaseline)
                    let expected =
                        FileManager.default.fileExists(atPath: destination.path)
                        ? try self.fileAccess.baseline(
                            destination,
                            permit: {
                                !permit.isCancelled
                            }
                        ) : nil
                    request.observe(.preparingBytes)
                    let data = try encoding.encode(snapshot.text.text(), catalog: catalog)
                    return try self.fileOperations.write(
                        using: self.fileAccess,
                        request: request,
                        data,
                        to: destination,
                        expected: expected,
                        replacing: true,
                        backup: backup
                    )
                }
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
            fileOperations.complete(request, error: CancellationError())
            mainWindow?.status.stringValue = "保存请求已取消，当前正文与原关联保持可用。"
        }
        catch {
            fileOperations.complete(request, error: error)
            if request.snapshot.requiresReconciliation
                && document.url?.resolvingSymlinksInPath().standardizedFileURL == resolved
            {
                // 原路径可能已经替换，未取得确认的基线不能继续作为自动覆盖依据。
                document.conflict = true
                document.failure = error.localizedDescription
            }
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
        guard await waitForOriginalSave(document) else {
            return
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
            if monitoring && document.buffer.primarySelection?.head == document.buffer.text.byteCount
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
    /// 返回：确认保护后移除文档并更新索引；失败保留正文，退出接管后不新增关闭请求。
    func closeDocument(_ id: UUID) async {
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        // 退出已固定成员收束范围，只有此前登记的关闭可以继续，新请求不能扩展这个集合。
        guard !closing, !document.closing else {
            return
        }
        if activeID == id {
            mainWindow?.editor.finishComposition()
        }
        document.closing = true
        closingDocumentIDs.insert(id)
        document.originalBindingTask?.cancel()
        document.setEditingSuspension(.documentClosing, active: true)
        defer {
            document.closing = false
            closingDocumentIDs.remove(id)
            if closing {
                // 已移除文档的最后视图也可能尚未退场，退出完成前仍不允许它接收未纳入工作区的新输入。
                document.setEditingSuspension(.applicationTermination, active: true)
            }
            document.setEditingSuspension(.documentClosing, active: false)
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
            document.savePermit?.cancel()
            // 发布系统调用尚未返回时不能移除文档后重新打开同一路径建立另一个写入者。
            guard document.savePermit?.hasActivePublication != true else {
                SystemIntegration.alert("关闭仍需等待", "目标发布已经进入系统调用；请在文件写入任务中查看实际结果，正文保持打开。")
                return
            }
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
        // 此关闭已经登记，退出会等待它完成后再固定最终成员，不能提前丢弃用户已确认的关闭意图。
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
