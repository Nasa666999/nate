import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：冲突选择绑定当前修订和可检查的磁盘证据，确认不能成为永久覆盖授权。
    /// 参数说明: 无。
    /// 返回：比较、单次保留本地写回、重新载入或取消，失败保留正文与恢复副本。
    func resolveSaveState() async {
        guard let document = active else {
            return
        }
        mainWindow?.editor.finishComposition()
        guard let url = document.url else {
            await saveAs(document)
            return
        }
        if !document.conflict {
            if document.recoveryError != nil {
                _ = await flushRecovery()
            }
            _ = await flush(document)
            refreshUI()
            return
        }
        let expected = try? await fileIO.run {
            try FileStorage.baseline(url)
        }
        let revision = document.buffer.revision
        let alert = NSAlert()
        alert.messageText = "外部文件与本地缓冲区冲突"
        alert.informativeText = (document.failure ?? "磁盘内容已经变化。") + "\n保留本地仅授权覆盖本次检查的磁盘内容；后续外部变化仍会暂停自动覆盖。"
        alert.addButton(withTitle: "比较磁盘与本地")
        alert.addButton(withTitle: "保留本地并写回")
        alert.addButton(withTitle: "载入外部内容")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard document.buffer.revision == revision else {
            SystemIntegration.alert("文档已变化", "请基于当前内容重新处理冲突。")
            return
        }
        if choice == .alertFirstButtonReturn {
            await compareWithDisk(document)
            return
        }
        if choice == .alertThirdButtonReturn {
            await reload(document)
            return
        }
        guard choice == .alertSecondButtonReturn else {
            return
        }
        guard let expected, !document.buffer.isReadOnly, !document.bindingChange else {
            SystemIntegration.alert("原目标不可覆盖", "目标缺失、只读或正在变更，请使用另存为建立明确的新目标。")
            return
        }
        guard await flushRecovery() else {
            return
        }
        document.bindingChange = true
        defer {
            document.bindingChange = false
        }
        if let task = document.saveTask {
            _ = await task.value
        }
        // 恢复落盘与在途写入均可挂起，授权只属于用户刚刚审阅的正文。
        guard document.buffer.revision == revision, document.url == url else {
            SystemIntegration.alert("文档已变化", "请基于当前正文与路径重新处理冲突。")
            return
        }
        let snapshot = document.buffer.snapshot
        let encoding = document.encoding
        let catalog = codecs
        do {
            let result = try await fileIO.run {
                try FileStorage.save(
                    encoding.encode(snapshot.text.text(), catalog: catalog),
                    to: url,
                    expected: expected
                )
            }
            document.baseline = result
            document.savedText = snapshot.text
            document.savedEncoding = encoding
            document.lastSavedRevision = snapshot.revision
            document.conflict = false
            document.failure = nil
            document.state = "已保存"
            document.evaluateDirty()
            refreshUI()
        }
        catch {
            document.failure = error.localizedDescription
            refreshUI()
        }
    }

    /// 业务作用：比较展示共同保存基线、本地与外部，比较本身不会覆盖文件。
    /// 参数说明:
    /// - document: 冲突文档。
    /// 返回：只读差异结果，正文及保存参数保持原状态。
    func compareWithDisk(_ document: WorkspaceDocument) async {
        guard let url = document.url else {
            return
        }
        let local = document.buffer.snapshot
        let base = document.savedText
        let encoding = document.encoding
        let catalog = codecs
        do {
            let output = try await fileIO.run {
                let external = try FileStorage.load(url, encoding: encoding, catalog: catalog)
                let original = TextTransforms.lines(base.text()).map(\.body)
                let current = TextTransforms.lines(local.text.text()).map(\.body)
                let disk = TextTransforms.lines(external.text).map(\.body)
                guard original.count + current.count + disk.count <= 100_000 else {
                    throw NateError.message("三方逐行比较超过 100000 行预算，请选择较小范围。")
                }
                let localDiff = current.difference(from: original).map {
                    String(describing: $0)
                }.joined(separator: "\n")
                let diskDiff = disk.difference(from: original).map {
                    String(describing: $0)
                }.joined(separator: "\n")
                return "共同保存基线 → 本地\n" + localDiff + "\n\n共同保存基线 → 外部磁盘\n" + diskDiff
            }
            mainWindow?.showResults(output)
        }
        catch {
            SystemIntegration.alert("无法比较冲突", error.localizedDescription)
        }
    }
}
