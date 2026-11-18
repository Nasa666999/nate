import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：当前编辑窗口的结果选择与来源复制共享取消入口，旧窗口回调不拥有当前剪贴板权限。
    /// 参数说明:
    /// - window: 正在装配操作回调的实际编辑窗口。
    /// 返回：保留原结果呈现通知，并连接弱窗口与弱拥有者的复制入口。
    func connectSearchResultSources(_ window: EditorWindow) {
        let previous = window.searchResults.onPresentationChange
        window.searchResults.onPresentationChange = {
            [weak self, weak window] in
            previous?()
            guard let self, self.mainWindow === window else {
                return
            }
            self.cancelSearchResultExport()
        }
        window.searchResults.onCopyLines = {
            [weak self, weak window] selection in
            guard let self, self.mainWindow === window else {
                return
            }
            self.copySearchResultLines(selection)
        }
    }

    /// 业务作用：用户改选结果、筛选、清除或退出时撤销旧复制，迟到源文件读取不能覆盖剪贴板。
    /// 参数说明: 无。
    /// 返回：操作身份先失效，随后取消实际读取并收回句柄，当前复制反馈结束等待状态。
    func cancelSearchResultExport() {
        let pending = resultExportTask != nil
        // 撤销发布资格必须先于取消通知，后台已经完成的旧文本同样不能发布。
        resultExportGeneration = UUID()
        resultExportTask?.cancel()
        resultExportTask = nil
        if pending, !closing {
            mainWindow?.searchResults.showOperationFeedback("源行复制已取消，剪贴板保留。")
        }
    }

    /// 业务作用：完整命中行复制固定来源证据与剪贴板状态，所有来源成功后才执行单次剪贴板发布。
    /// 参数说明:
    /// - selection: 当前结果视图选择的稳定批次、文件和命中身份。
    /// 返回：原文档与结果仍有效且剪贴板未被更新时复制完整源行，失败保留旧剪贴板与正文。
    func copySearchResultLines(_ selection: [SearchResultHitSelection]) {
        cancelSearchResultExport()
        guard !closing, let window = mainWindow, !window.searchResults.isEditingInput else {
            return
        }
        do {
            let captured = try captureSearchResultLines(selection)
            window.searchResults.showOperationFeedback("正在复验完整源行，完成后更新剪贴板。")
            let sources = captured.sources
            let catalog = codecs
            let request = resultExportGeneration
            let presentation = window.resultGeneration
            let clipboard = NSPasteboard.general.changeCount
            // 结果选择、窗口与每个原文档实例共同授予发布资格，等待不能复活已关闭或已改写的来源。
            let permitted: @MainActor () -> Bool = {
                [weak self, weak window] in
                guard let self, let window, !self.closing, !Task.isCancelled,
                    self.mainWindow === window, self.resultExportGeneration == request,
                    window.resultGeneration == presentation, !window.searchResults.isEditingInput
                else {
                    return false
                }
                let live = Set(
                    self.documents.map {
                        ObjectIdentifier($0)
                    }
                )
                return captured.authorities.allSatisfy {
                    authority in
                    guard let document = authority.document else {
                        return false
                    }
                    return live.contains(ObjectIdentifier(document)) && authority.matches(document)
                }
            }
            resultExportTask = Task {
                [weak self, weak window] in
                guard let self, let window else {
                    return
                }
                defer {
                    if self.resultExportGeneration == request {
                        self.resultExportTask = nil
                    }
                }
                do {
                    guard permitted() else {
                        self.reportChangedSearchResultSource(request: request, window: window)
                        return
                    }
                    let result = try await self.readIO.readCancellable {
                        token in
                        try SearchResultLineExport.prepare(
                            sources,
                            access: self.fileAccess,
                            catalog: catalog,
                            token: token
                        )
                    }
                    // 正文或结果的迟到变化不授予复制资格，其他应用的新剪贴板内容也属于更新的用户意图。
                    guard permitted() else {
                        self.reportChangedSearchResultSource(request: request, window: window)
                        return
                    }
                    guard NSPasteboard.general.changeCount == clipboard else {
                        window.searchResults.showOperationFeedback("剪贴板已改变，未覆盖新内容；可重新复制命中行。")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    window.searchResults.showOperationFeedback("已复制 \(result.lines) 个完整命中行，行间使用 LF。")
                }
                catch {
                    if permitted(), !(error is CancellationError) {
                        window.searchResults.showOperationFeedback(error.localizedDescription)
                    }
                    else {
                        self.reportChangedSearchResultSource(request: request, window: window)
                    }
                }
            }
        }
        catch {
            window.searchResults.showOperationFeedback(error.localizedDescription)
        }
    }

    /// 业务作用：来源独立变化结束当前复制反馈，旧操作不能覆盖后来结果选择或新窗口的状态。
    /// 参数说明:
    /// - request: 正在结束的复制身份。
    /// - window: 原复制所属的实际窗口。
    /// 返回：仍为当前操作时说明来源已变，已经失权的操作不发布反馈。
    private func reportChangedSearchResultSource(request: UUID, window: EditorWindow) {
        guard !closing, mainWindow === window, resultExportGeneration == request else {
            return
        }
        window.searchResults.showOperationFeedback("结果或源正文已改变，未复制命中行；剪贴板保留。")
    }

    /// 业务作用：复制前将稳定结果身份解析为固定内存正文或磁盘证据，预览上下文不参与源行输出。
    /// 参数说明:
    /// - selection: 用户当前确认的完整结果选择。
    /// 返回：至多十万命中的临时只读来源与弱文档权威，失效来源整体拒绝。
    private func captureSearchResultLines(_ selection: [SearchResultHitSelection]) throws -> (
        sources: [SearchResultLineSource], authorities: [SearchDocumentAuthority]
    ) {
        guard !selection.isEmpty, selection.count <= 100_000 else {
            throw NateError.message("没有可复制的命中行，或所选来源超过容量。")
        }
        var sources: [SearchResultLineSource] = []
        var authorities: [SearchDocumentAuthority] = []
        var remaining = 100_000
        let batches = Dictionary(
            uniqueKeysWithValues: resultBatches.map {
                ($0.presentation.id, $0)
            }
        )
        let live = Set(
            documents.map {
                ObjectIdentifier($0)
            }
        )
        var files: [UUID: [UUID: SearchResultFilePresentation]] = [:]
        var seen: [UUID: Set<UUID>] = [:]
        for group in selection {
            // 只解析仍保留且不重复的来源组，外来的旧身份不能绕过整轮容量或复用已删除结果。
            guard !group.hits.isEmpty, group.hits.count <= remaining,
                seen[group.batch, default: []].insert(group.file).inserted,
                let batch = batches[group.batch]
            else {
                throw NateError.message("所选结果已过期或超过十万命中，请重新选择；剪贴板保留。")
            }
            if files[group.batch] == nil {
                files[group.batch] = Dictionary(
                    uniqueKeysWithValues: batch.presentation.files.map {
                        ($0.id, $0)
                    }
                )
            }
            guard let file = files[group.batch]?[group.file] else {
                throw NateError.message("所选文件结果已被删除，请重新选择；剪贴板保留。")
            }
            remaining -= group.hits.count
            let wanted = Set(group.hits)
            let rows = file.rows.filter {
                wanted.contains($0.id)
            }
            guard rows.count == group.hits.count,
                let first = rows.first, let target = batch.destinations[first.id]
            else {
                throw NateError.message("所选命中已被删除或身份重复，请重新选择；剪贴板保留。")
            }
            let content: SearchResultLineContent
            // 内存结果必须保持原实例与原修订，磁盘结果必须具有完整字节与编码证据，二者不能互相降级。
            if let id = target.documentID, let authority = target.authority,
                let document = authority.document, live.contains(ObjectIdentifier(document)),
                document.buffer.id == id, authority.matches(document),
                target.revision == document.buffer.revision
            {
                content = .buffer(document.buffer.text)
                authorities.append(authority)
            }
            else if target.documentID == nil, let url = target.url,
                let baseline = target.diskBaseline, let encoding = target.diskEncoding
            {
                content = .disk(url, baseline: baseline, encoding: encoding)
            }
            else {
                throw NateError.message("命中行来源已关闭、重开或改变，请重新搜索；剪贴板保留。")
            }
            for row in rows {
                // 一个文件分组不能混入另一来源的偏移，显示条目与导航证据必须完整对应后才能读取。
                guard let evidence = batch.destinations[row.id], evidence.range == row.range,
                    evidence.documentID == target.documentID, evidence.revision == target.revision,
                    evidence.authority?.document === target.authority?.document,
                    evidence.url == target.url, evidence.diskBaseline == target.diskBaseline,
                    evidence.diskEncoding == target.diskEncoding
                else {
                    throw NateError.message("命中行的来源证据不一致，请重新搜索；剪贴板保留。")
                }
            }
            sources.append(SearchResultLineSource(content: content, ranges: rows.map(\.range)))
        }
        return (sources, authorities)
    }
}
