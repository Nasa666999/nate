import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：按当前标签顺序循环切换，不生成重复缓冲区。
    /// 参数说明:
    /// - forward: 是否切换到后一个标签。
    /// 返回：激活对应文档。
    func cycleTab(forward: Bool) {
        guard !documents.isEmpty,
            let index = documents.firstIndex(where: {
                $0.buffer.id == activeID
            })
        else {
            return
        }
        activate(documents[(index + (forward ? 1 : documents.count - 1)) % documents.count].buffer.id)
    }

    /// 业务作用：批量关闭固定开始时的文档集合，逐个执行内容保护。
    /// 参数说明:
    /// - command: 明确的关闭范围。
    /// - reference: 上下文被点击标签，为空时使用活动标签。
    /// 返回：新建的替代空标签不会误加入原关闭集合。
    func closeGroup(_ command: String, reference: UUID? = nil) {
        let reference = reference ?? activeID
        let index =
            documents.firstIndex(where: {
                $0.buffer.id == reference
            }) ?? 0
        let targets = documents.enumerated().filter {
            offset,
            document in
            switch command {
            case "closeOthers": return document.buffer.id != reference
            case "closeLeft": return offset < index
            case "closeRight": return offset > index
            case "closeClean": return !document.isDirty
            case "closeUnpinned": return !document.pinned
            default: return true
            }
        }.map {
            $0.element.buffer.id
        }
        Task {
            for id in targets {
                await closeDocument(id)
            }
        }
    }

    /// 业务作用：按明确的逻辑行与字形列导航，软换行不改变真实位置。
    /// 参数说明: 无。
    /// 返回：将光标放到合法边界。
    func gotoLine() {
        guard let active, let value = SystemIntegration.prompt("跳转", "输入 行号 或 行号:列号（从 1 开始）", initial: "1")
        else {
            return
        }
        let parts = value.split(separator: ":").compactMap {
            Int($0)
        }
        guard let requested = parts.first, requested > 0 else {
            return
        }
        let row = min(active.buffer.text.lineCount - 1, requested - 1)
        let range = active.buffer.text.lineRange(row, includeEnding: false)
        let prefix = active.buffer.text.text(in: range).prefix(max(0, (parts.count > 1 ? parts[1] : 1) - 1))
        mainWindow?.editor.setCaret(range.lower + prefix.utf8.count)
    }

    /// 业务作用：统计用户当前全文及选区，不把字节与字符计数混为一项。
    /// 参数说明: 无。
    /// 返回：明确显示行、字形、标量、UTF-16 和字节数量。
    func statistics() {
        guard let active else {
            return
        }
        let text = active.buffer.text.text()
        SystemIntegration.alert(
            "文档统计",
            "逻辑行：\(active.buffer.text.lineCount)\n字形簇：\(text.count)\nUnicode 标量：\(text.unicodeScalars.count)\nUTF-16 单元：\(text.utf16.count)\nUTF-8 字节：\(text.utf8.count)\n词数：\(text.split(whereSeparator: \.isWhitespace).count)"
        )
    }

    /// 业务作用：转换编码先完整验证可表示性，再一次发布保存参数。
    /// 参数说明:
    /// - index: 编码菜单中的明确代码页。
    /// 返回：验证失败时不改变当前编码和正文。
    func convertEncoding(_ index: Int) async {
        let catalog = codecs
        guard TextEncoding.available.indices.contains(index), let active else {
            return
        }
        let snapshot = active.buffer.snapshot
        let encoding = TextEncoding.available[index]
        do {
            _ = try await fileIO.run {
                try encoding.encode(snapshot.text.text(), catalog: catalog)
            }
            guard active.buffer.revision == snapshot.revision else {
                throw NateError.staleRevision
            }
            try active.setEncoding(encoding)
            active.dirtyHint = true
            refreshUI()
        }
        catch {
            SystemIntegration.alert("无法转换编码", error.localizedDescription)
        }
    }

    /// 业务作用：外部变化以身份和内容复验判定，非活动标签同样受保护。
    /// 参数说明:
    /// - force: 激活检查忽略轻量标记，周期观察只在元数据变化时读取摘要。
    /// 返回：冲突暂停原路径覆盖；监视模式只读更新，不把删除解释为空文件。
    func inspectExternalChanges(force: Bool = true) async {
        for document in documents
        where document.url != nil && document.saveTask == nil && !document.bindingChange && !document.closing
        {
            guard let url = document.url, let expected = document.baseline else {
                continue
            }
            do {
                let stamp = try await readIO.read {
                    try FileStorage.stamp(url)
                }
                if !force && externalStamps[document.buffer.id] == stamp {
                    continue
                }
                let current = try await readIO.read {
                    try self.fileAccess.baseline(url)
                }
                guard document.saveTask == nil, !document.bindingChange, document.baseline == expected,
                    document.url == url,
                    documents.contains(where: {
                        $0 === document
                    })
                else {
                    continue
                }
                externalStamps[document.buffer.id] = stamp
                if current != expected {
                    document.evaluateDirty()
                    if document.monitoring && !document.isDirty {
                        await reload(document)
                    }
                    else {
                        document.conflict = true
                        document.failure = "外部文件已变化；请重新载入、比较或另存为。自动覆盖已暂停。"
                    }
                }
            }
            catch {
                document.conflict = true
                document.failure = "原目标缺失或不可访问，自动保存不会重建：" + error.localizedDescription
            }
        }
        refreshUI()
    }

    /// 业务作用：重命名先收束在途保存，未命名标签改名不创建磁盘文件。
    /// 参数说明: 无。
    /// 返回：成功后一起更新目标、名称和磁盘证据。
    func renameDocument() async {
        guard let active, let name = SystemIntegration.prompt("重命名", "输入新名称", initial: active.name),
            !name.isEmpty, !name.contains("/")
        else {
            return
        }
        guard let oldURL = active.url else {
            active.name = name
            refreshUI()
            return
        }
        guard await flush(active) else {
            return
        }
        // 先排除新保存请求，再收束挂起窗口内可能启动的最后一个写入者。
        guard !active.bindingChange else {
            return
        }
        active.bindingChange = true
        defer {
            active.bindingChange = false
        }
        guard await waitForOriginalSave(active) else {
            return
        }
        let destination = oldURL.deletingLastPathComponent().appendingPathComponent(name)
        let sourceKey = oldURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationKey = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourceKey != destinationKey else {
            return
        }
        guard
            !documents.contains(where: {
                $0 !== active && $0.url?.resolvingSymlinksInPath().standardizedFileURL.path == destinationKey
            })
        else {
            SystemIntegration.alert("目标已打开", "同一目标不能建立两个原文件写入者。")
            return
        }
        let owner = UUID()
        guard reserveTarget(sourceKey, owner: owner) else {
            return
        }
        defer {
            releaseTarget(sourceKey, owner: owner)
        }
        guard reserveTarget(destinationKey, owner: owner) else {
            return
        }
        defer {
            releaseTarget(destinationKey, owner: owner)
        }
        let baseline = active.baseline
        let request = fileOperations.begin(
            title: "重命名文件",
            target: destination,
            documentID: active.buffer.id,
            revision: active.buffer.revision,
            targetGeneration: active.targetGeneration
        )
        active.savePermit = request.permission
        active.saveOperation = request
        defer {
            if active.saveOperation?.id == request.id {
                active.saveOperation = nil
                active.savePermit = nil
            }
        }
        do {
            let result = try await fileIO.run {
                try self.fileOperations.perform(request) {
                    request.observe(.waitingForAccess)
                    return try self.fileAccess.withMove(
                        from: oldURL,
                        to: destination,
                        permit: {
                            !request.permission.isCancelled
                        }
                    ) {
                        source,
                        target in
                        request.observe(.checkingBaseline)
                        // 协调访问不替代原磁盘证据，目标身份变化时必须停止路径副作用。
                        guard
                            try FileStorage.baseline(
                                source,
                                permit: {
                                    !request.permission.isCancelled
                                }
                            ) == baseline
                        else {
                            throw NateError.message("重命名前原文件已变化。")
                        }
                        request.observe(.publishing)
                        try request.permission.withPublication {
                            try FileManager.default.moveItem(at: source, to: target)
                        }
                        request.observe(.confirmingSavedFile)
                        let result = try FileStorage.baseline(target)
                        // 移动后的文件必须仍是原内容和身份，否则不能把新路径发布为可信保存点。
                        guard result.device == baseline?.device, result.inode == baseline?.inode,
                            result.digest == baseline?.digest
                        else {
                            throw NateError.message("重命名后的目标内容或身份已经变化，请核验目标。")
                        }
                        return result
                    }
                }
            }
            active.targetGeneration += 1
            active.url = destination
            active.name = name
            active.baseline = result
            refreshUI()
        }
        catch {
            fileOperations.complete(request, error: error)
            if request.snapshot.requiresReconciliation {
                active.conflict = true
                active.failure = error.localizedDescription
            }
            SystemIntegration.alert("重命名", error.localizedDescription)
        }
    }

    /// 业务作用：移到废纸篓后解除自动保存目标，后续周期不能重建旧路径。
    /// 参数说明: 无。
    /// 返回：保留可编辑正文，路径写入权失效。
    func trashDocument() async {
        guard let active, let url = active.url, await flush(active) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "将 \(active.name) 移到废纸篓？"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard !active.bindingChange else {
            return
        }
        // 移除目标期间禁止周期保存重建旧路径，完成后再解除绑定。
        active.bindingChange = true
        defer {
            active.bindingChange = false
        }
        guard await waitForOriginalSave(active) else {
            return
        }
        let targetKey = url.resolvingSymlinksInPath().standardizedFileURL.path
        let owner = UUID()
        guard reserveTarget(targetKey, owner: owner) else {
            return
        }
        defer {
            releaseTarget(targetKey, owner: owner)
        }
        let expected = active.baseline
        let request = fileOperations.begin(
            title: "移到废纸篓",
            target: url,
            documentID: active.buffer.id,
            revision: active.buffer.revision,
            targetGeneration: active.targetGeneration
        )
        active.savePermit = request.permission
        active.saveOperation = request
        defer {
            if active.saveOperation?.id == request.id {
                active.saveOperation = nil
                active.savePermit = nil
            }
        }
        do {
            try await fileIO.run {
                try self.fileOperations.perform(request) {
                    request.observe(.waitingForAccess)
                    try self.fileAccess.withWrite(
                        at: url,
                        intent: .deleting,
                        permit: {
                            !request.permission.isCancelled
                        }
                    ) {
                        target in
                        request.observe(.checkingBaseline)
                        // 删除仅针对刚确认的原文件，不能因系统协调成功而绕过内容复验。
                        guard
                            try FileStorage.baseline(
                                target,
                                permit: {
                                    !request.permission.isCancelled
                                }
                            ) == expected
                        else {
                            throw NateError.message("移到废纸篓前原文件已经变化，请重新检查。")
                        }
                        request.observe(.publishing)
                        try request.permission.withPublication {
                            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                        }
                        request.observe(.published)
                    }
                }
            }
            active.targetGeneration += 1
            active.url = nil
            active.pendingOriginalPath = nil
            active.pendingOriginalBaseline = nil
            active.baseline = nil
            active.state = "原文件已移到废纸篓 · 正文保留为临时文档"
            refreshUI()
            _ = await flushRecovery()
        }
        catch {
            fileOperations.complete(request, error: error)
            if request.snapshot.requiresReconciliation {
                active.conflict = true
                active.failure = error.localizedDescription
            }
            SystemIntegration.alert("无法移到废纸篓", error.localizedDescription)
        }
    }
}
