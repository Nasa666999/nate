import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：所有打开入口先验证文件 URL，再按真实身份去重，避免错误路径访问和竞争自动保存。
    /// 参数说明:
    /// - url: Finder、对话框或 CLI 提供的路径。
    /// - explicitEncoding: 用户选择的重新解释代码页。
    /// - targetWindow: 明确发起打开的编辑窗口，省略时捕获请求开始时的当前窗口。
    /// - placement: Finder 或命令行整组请求的窗口意图，优先采用组内窗口。
    /// - activateOnOpen: 是否在读取完成后立即激活；异步结果导航可先建立后台标签再复验自己的焦点权限。
    /// - permit: 主执行域中的发布权限，失效时不添加标签、改变焦点或发布迟到错误。
    /// 返回：实际打开的文档；无效 URL 在类型探测前拒绝，失败返回空，不误用先前活动标签。
    @discardableResult
    func openFile(
        _ url: URL,
        explicitEncoding: TextEncoding? = nil,
        in targetWindow: EditorWindow? = nil,
        placement: FileOpenPlacement? = nil,
        activateOnOpen: Bool = true,
        permit: @MainActor () -> Bool = {
            true
        }
    ) async -> WorkspaceDocument? {
        let window = placement?.window ?? targetWindow ?? mainWindow
        /// 业务作用：读取和解码中的每个挂起点共用原窗口的发布门禁。
        /// 参数说明: 无。
        /// 返回：原窗口和调用权仍有效，且应用没有进入退出时为真。
        func mayPublish() -> Bool {
            permit() && !closing && !Task.isCancelled && isWorkspaceWindowAvailable(window)
        }
        /// 业务作用：已有及新读入文档共享组内窗口逻辑，后台查询只登记文档。
        /// 参数说明:
        /// - document: 已按真实文件身份统一的文档。
        /// 返回：后台登记或实际展示成功时为真。
        func display(_ document: WorkspaceDocument) -> Bool {
            !activateOnOpen
                || (placement?.present(document, using: self) ?? activate(document.buffer.id, in: window))
        }
        // 打开请求的调用权也可能被后来的导航撤销，读取前不能先改变原视图。
        guard mayPublish() else {
            return nil
        }
        let catalog = codecs
        do {
            // 文件类型探测也会访问目标，必须先验证原始 URL，不能先查询被转义成另一名称的路径。
            try FileStorage.validateFileURL(url)
            window?.status.stringValue = "正在读取 · " + url.lastPathComponent + " · 可在工具菜单取消读取"
            // 类型探测也可能等待外置盘或系统授权，必须使用有界读取通道而不阻塞主事件循环。
            let directory = try await readIO.readCancellable {
                token in
                try token.check()
                let value = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                try token.check()
                return value
            }
            // 类型证据返回时原导航可能已经撤销，目录和文件都先复验调用权再进入后续流程。
            guard mayPublish() else {
                return nil
            }
            if directory {
                if activateOnOpen {
                    if let placement {
                        if let destination = placement.prepareWindow(using: self) {
                            await showFolder(url, in: destination)
                        }
                    }
                    else {
                        await showFolder(url, in: window)
                    }
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
            guard mayPublish() else {
                return nil
            }
            if let existing = boundWorkspaceDocument(
                for: loaded.url,
                path: loaded.baseline.resolvedPath,
                baseline: loaded.baseline
            ) {
                guard !existing.closing else {
                    throw NateError.message("该文档正在确认关闭，请稍后重新打开。")
                }
                return display(existing) ? existing : nil
            }
            // 保存或批量替换还未发布绑定时，不能从旧磁盘快照建立另一个写入者。
            guard targetReservation(for: loaded.baseline.resolvedPath, baseline: loaded.baseline) == nil
            else {
                throw NateError.message("该目标正在完成文件操作，请稍后重新打开。")
            }
            guard documents.count < 1024 else {
                throw NateError.message("工作区已打开 1024 个文档，请先关闭部分文档。")
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
            if activateOnOpen && placement?.needsWindow == true {
                beginWorkspaceTabGroups()
            }
            documents.append(document)
            recentFiles =
                [url.path]
                + recentFiles.filter {
                    !$0.utf8.elementsEqual(url.path.utf8)
                }
            let displayed = display(document)
            if !activateOnOpen || !displayed {
                attachWorkspaceTab(document.buffer.id, to: window)
                refreshUI()
            }
            buildMenus()
            return displayed ? document : nil
        }
        catch {
            if error is CancellationError {
                return nil
            }
            // 迟到错误同样需要原调用权，不能用旧读取的提示覆盖新窗口或新查询。
            guard mayPublish() else {
                return nil
            }
            if !activateOnOpen {
                window?.status.stringValue = "无法打开结果文件：" + error.localizedDescription
                return nil
            }
            if error is ReadDeadlineExceeded {
                window?.showResults("读取未完成：" + url.path + "\n" + error.localizedDescription)
            }
            else if error is FileDecodingFailure, explicitEncoding == nil {
                return await offerDecode(
                    url,
                    reason: error.localizedDescription,
                    in: window,
                    placement: placement,
                    permit: permit
                )
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
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishWorkspaceCompositions(documentID: document.buffer.id) else {
            return
        }
        guard await waitForOriginalSave(document) else {
            return
        }
        guard
            let destination = SystemIntegration.chooseSave(
                name: document.name,
                directory: fileDialogDirectory()
            )
        else {
            return
        }
        rememberSelectedFileDirectory(destination)
        let snapshot = document.buffer.snapshot
        let changeSavePoint = copy ? nil : document.buffer.changeHistorySavePoint()
        let encoding = document.encoding
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
        var savingOriginal = false
        do {
            request.observe(.checkingBaseline)
            let target = try await readIO.readCancellable {
                token -> (path: String, baseline: DiskBaseline?) in
                try token.check()
                try permit.check()
                try FileStorage.validateFileURL(destination)
                let baseline =
                    FileManager.default.fileExists(atPath: destination.path)
                    ? try self.fileAccess.baseline(
                        destination,
                        permit: {
                            !token.isCancelled && !permit.isCancelled
                        }
                    ) : nil
                let path =
                    baseline?.resolvedPath ?? destination.resolvingSymlinksInPath().standardizedFileURL.path
                return (path, baseline)
            }
            // 读取期间新打开的硬链接也可取得文件权，必须在挂起结束后同时检查路径及物理身份。
            try permit.check()
            guard document.saveOperation?.id == request.id,
                document.targetGeneration == request.targetGeneration,
                document.bindingChange
            else {
                throw CancellationError()
            }
            guard
                boundWorkspaceDocument(
                    for: destination,
                    path: target.path,
                    baseline: target.baseline,
                    excluding: document
                ) == nil
            else {
                throw NateError.message("目标已在另一标签打开，同一文件只允许一个写入者。")
            }
            savingOriginal = document.matchesBoundFile(
                destination,
                path: target.path,
                baseline: target.baseline
            )
            if savingOriginal && (copy || document.buffer.isReadOnly) {
                throw NateError.message(
                    copy ? "副本不能与原文件指向同一目标。" : "原文件为编辑器只读，请先解除只读或选择不同目标。"
                )
            }
            guard reserveTarget(target.path, baseline: target.baseline, owner: request.id) else {
                throw NateError.message("目标或其别名尚有文件动作，请稍后重试。")
            }
            defer {
                releaseTarget(target.path, owner: request.id)
            }
            let backup = try saveBackupRequest(request)
            let result = try await fileIO.run {
                try self.fileOperations.perform(request) {
                    request.observe(.preparingBytes)
                    let data = try encoding.encode(snapshot.text.text(), catalog: catalog)
                    return try self.fileOperations.write(
                        using: self.fileAccess,
                        request: request,
                        data,
                        to: destination,
                        expected: target.baseline,
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
                        !$0.utf8.elementsEqual(destination.path.utf8)
                    }
                scheduleSavedModifications(changeSavePoint, document: document)
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
            if request.snapshot.requiresReconciliation && savingOriginal {
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
        // 重新载入会替换已提交正文，先确认目标全部候选，失败不能撤去覆盖层后改用磁盘旧内容。
        guard finishWorkspaceCompositions(documentID: document.buffer.id) else {
            return
        }
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
            let changeSavePoint = document.buffer.changeHistorySavePoint()
            for window in editorWindows {
                window.refreshEditors()
            }
            if monitoring && document.buffer.primarySelection?.head == document.buffer.text.byteCount
                && mainWindow?.editor.document.id == document.buffer.id
            {
                mainWindow?.editor.revealSelection()
            }
            refreshUI()
            scheduleSavedModifications(changeSavePoint, document: document)
        }
        catch is CancellationError {
            return
        }
        catch {
            SystemIntegration.alert("无法重新载入", error.localizedDescription)
        }
    }

    /// 业务作用：关闭最后视图时按用户选择确认原文件、恢复副本或明确丢弃的工作区状态。
    /// 参数说明:
    /// - id: 被关闭文档身份。
    /// 返回：所选动作与工作区索引都已确认后移除文档；失败保留正文，退出接管后不新增关闭请求。
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
        // 先完成该正文所有克隆的候选，再取得关闭保护；失败不能归档不含候选的旧正文后移除窗口。
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishWorkspaceCompositions(documentID: id) else {
            return
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
        var discardChanges = false
        if archiveNeeded {
            let alert = NSAlert()
            alert.messageText = "关闭临时文档 \(document.name)"
            alert.informativeText = "可以保存到文件、保留独立恢复副本，或丢弃这份草稿正文。最近 100 份明确保留的内容可从文件菜单恢复。"
            alert.addButton(withTitle: "另存为")
            alert.addButton(withTitle: "保留恢复副本并关闭")
            alert.addButton(withTitle: "丢弃并关闭").hasDestructiveAction = true
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                await saveAs(document)
                guard document.url != nil else {
                    return
                }
                archiveNeeded = false
            }
            else if choice == .alertThirdButtonReturn {
                // 丢弃只收束工作区引用；此前未落盘的正文不能为归档或恢复入口新增持久化副本。
                archiveNeeded = false
                discardChanges = true
            }
            else if choice != .alertSecondButtonReturn {
                return
            }
        }
        if !discardChanges, !(await flush(document)) {
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
            alert.addButton(withTitle: "丢弃未保存的编辑并关闭").hasDestructiveAction = true
            let choice = alert.runModal()
            if choice == .alertSecondButtonReturn {
                await saveAs(document)
                return
            }
            let discard = NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
            )
            if choice == discard {
                // 待实际确认或尚未开始的原文件请求已失去新发布权限，关闭只移除未保存编辑的恢复入口。
                archiveNeeded = false
                discardChanges = true
            }
            else {
                guard choice == .alertThirdButtonReturn, await flushRecovery() else {
                    return
                }
                archiveNeeded = true
            }
        }
        if archiveNeeded {
            guard await flushRecovery(), let reference = document.recoveryReference, let store = recovery
            else {
                return
            }
            do {
                try await archiveRecoveryReference(reference, using: store)
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
            activeID = workspaceTabDocuments(in: mainWindow).first?.buffer.id ?? documents.first?.buffer.id
        }
        guard await flushRecovery() else {
            documents.insert(document, at: min(oldIndex, documents.count))
            activate(id)
            SystemIntegration.alert("关闭未完成", "打开文档索引未能可靠更新，内容保持打开。")
            return
        }
        if !discardChanges || document.url != nil {
            recentClosed.append(
                ClosedTab(
                    url: archiveNeeded ? nil : document.url,
                    recovery: archiveNeeded ? document.recoveryReference : nil,
                    name: document.name
                )
            )
        }
        externalStamps.removeValue(forKey: id)
        if recentClosed.count > 20 {
            recentClosed.removeFirst()
        }
        let fallback = active ?? documents.first ?? newDocument(activateOnCreate: false)
        activeID = fallback.buffer.id
        retireWorkspaceDocument(id, fallback: fallback)
        refreshUI()
    }
}
