import AppKit
import NateCore
import NateStorage
import NateUI

private struct SearchResultPathSource {
    let batch: SearchResultBatchState
    let url: URL
}

extension ApplicationController {
    /// 业务作用：结果选择或输入变化后撤销旧路径打开，迟到读取不能添加标签或取得正文焦点。
    /// 参数说明: 无。
    /// 返回：身份先失效再取消实际读取，已经完成的标签保留。
    func cancelSearchResultPathOpen() {
        let pending = resultPathOpenTask != nil
        // 原意图失权必须先于底层取消，已返回但尚未回到主执行域的读取同样不能发布。
        resultPathOpenGeneration = UUID()
        resultPathOpenTask?.cancel()
        resultPathOpenTask = nil
        if pending, !closing {
            mainWindow?.searchResults.showOperationFeedback("路径打开已取消；已经打开的标签保留。")
        }
    }

    /// 业务作用：显式打开当前选择的文件路径，按工作区统一规则读取当前内容，不应用过期结果偏移。
    /// 参数说明:
    /// - selection: 用户在当前可见结果中明确选择的文件分组。
    /// 返回：至多二十个原始路径去重后依次打开，全部等待结束后激活最后成功文件；失权停止后续打开。
    func openSearchResultPaths(_ selection: [SearchResultFileSelection]) {
        cancelSearchResultPathOpen()
        cancelSearchResultExport()
        cancelProjectOpen()
        directoryWorkspace?.cancelOpen()
        cancelIncrementalSearch(resetOrigin: true)
        resultNavigationGeneration = UUID()
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        // 打开路径会交接正文焦点，未确认输入与已经开始的退出都不能授予这份权限。
        guard !closing, let window = mainWindow, !window.hasMarkedEditorInput,
            !window.searchResults.isEditingInput, findWindow?.isEditingInput != true,
            window.editor.document === active?.buffer
        else {
            return
        }
        do {
            let sources = try captureSearchResultPaths(selection)
            let request = resultPathOpenGeneration
            let presentation = window.resultGeneration
            let movement = searchNavigationGeneration
            let input = SearchRequestInput(findWindow)
            let inputs = findWindow?.inputIdentities
            let revision = active?.buffer.revision
            let selections = window.editor.viewSelections
            let documentSelections = active?.buffer.selections
            let panel = window.searchResults.window
            let responder = panel?.firstResponder
            let keyWindow = NSApp.keyWindow
            let modalWindow = NSApp.modalWindow
            let permitted: @MainActor () -> Bool = {
                [
                    weak self, weak window, weak origin = active?.buffer, weak editor = window.editor,
                    weak panel, weak responder, weak keyWindow, weak modalWindow
                ] in
                // 当前窗口、真实视图和原光标共同约束交接，等待期间的新选择不能被旧路径意图覆盖。
                guard let self, let window, !self.closing, !Task.isCancelled,
                    self.resultPathOpenGeneration == request, self.mainWindow === window,
                    window.resultGeneration == presentation, !window.searchResults.isEditingInput,
                    !window.hasMarkedEditorInput, self.findWindow?.isEditingInput != true,
                    self.searchNavigationGeneration == movement, input.matches(self.findWindow),
                    self.findWindow?.inputIdentities == inputs, window.editor === editor,
                    editor?.document === origin, self.active?.buffer === origin, origin?.revision == revision,
                    editor?.viewSelections == selections, origin?.selections == documentSelections,
                    window.searchResults.window === panel, panel?.firstResponder === responder,
                    NSApp.keyWindow === keyWindow,
                    NSApp.modalWindow === modalWindow
                else {
                    return false
                }
                return sources.allSatisfy {
                    source in
                    self.resultBatches.contains {
                        $0 === source.batch
                    }
                }
            }
            window.searchResults.showOperationFeedback("正在打开 \(sources.count) 个所选路径。")
            resultPathOpenTask = Task {
                [weak self, weak window] in
                guard let self, let window else {
                    return
                }
                defer {
                    if self.resultPathOpenGeneration == request {
                        self.resultPathOpenTask = nil
                    }
                }
                var opened = 0
                var last: WorkspaceDocument?
                for source in sources {
                    guard permitted() else {
                        self.reportStoppedSearchResultPaths(request: request, window: window, opened: opened)
                        return
                    }
                    let document = await self.openFile(source.url, activateOnOpen: false, permit: permitted)
                    guard permitted() else {
                        self.reportStoppedSearchResultPaths(request: request, window: window, opened: opened)
                        return
                    }
                    if let document {
                        opened += 1
                        last = document
                    }
                }
                // 全部读取与交接权威在同一执行域内复验后才激活，不沿旧匹配范围移动新正文的光标。
                if let last {
                    self.activate(last.buffer.id)
                    window.window?.makeFirstResponder(window.editor)
                }
                window.searchResults.showOperationFeedback(
                    "已打开 \(opened) 个路径；\(sources.count - opened) 个未打开。"
                )
            }
        }
        catch {
            window.searchResults.showOperationFeedback(error.localizedDescription)
        }
    }

    /// 业务作用：选择与来源仍属于原结果时才解释原始路径，重复批次不重复打开同一路径。
    /// 参数说明:
    /// - selection: 当前明确选择的文件身份集合。
    /// 返回：至多二十个去重后的合法文件 URL；缺失来源或非法原始路径在任何文件探测前失败。
    private func captureSearchResultPaths(_ selection: [SearchResultFileSelection]) throws
        -> [SearchResultPathSource]
    {
        guard !selection.isEmpty, selection.count <= 100_000 else {
            throw NateError.message("请先选择需要打开的结果路径。")
        }
        let batches = Dictionary(
            uniqueKeysWithValues: resultBatches.map {
                ($0.presentation.id, $0)
            }
        )
        var files: [UUID: [UUID: SearchResultFilePresentation]] = [:]
        var paths: Set<Data> = []
        var sources: [SearchResultPathSource] = []
        for item in selection {
            // 结果被清除后不能继续借用其文件名，批次身份必须先于 URL 构造成立。
            guard let batch = batches[item.batch] else {
                throw NateError.message("所选结果批次已移除，请重新选择路径。")
            }
            if files[item.batch] == nil {
                files[item.batch] = Dictionary(
                    uniqueKeysWithValues: batch.presentation.files.map {
                        ($0.id, $0)
                    }
                )
            }
            guard let file = files[item.batch]?[item.file], let path = file.path else {
                throw NateError.message("所选结果没有当前文件路径，请重新选择。")
            }
            // Foundation 解释路径前拒绝 NUL 与外来网络路径，不能让截断或重解释改变用户选中的目标。
            guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.utf8.contains(0) else {
                throw NateError.message("所选结果路径不是有效的本机绝对路径，尚未访问文件。")
            }
            if !paths.insert(Data(path.utf8)).inserted {
                continue
            }
            guard sources.count < 20 else {
                throw NateError.message("一次最多打开二十个所选路径，请缩小选择范围。")
            }
            let url = URL(fileURLWithPath: path, isDirectory: false)
            try FileStorage.validateFileURL(url)
            sources.append(SearchResultPathSource(batch: batch, url: url))
        }
        return sources
    }

    /// 业务作用：独立光标或窗口变化结束旧路径打开的反馈，已失权请求不能覆盖新操作。
    /// 参数说明:
    /// - request: 正在停止的打开身份。
    /// - window: 原结果所属编辑窗口。
    /// - opened: 已经完成的路径数量。
    /// 返回：当前请求说明完成数量和停止原因，后来请求的反馈保持不变。
    private func reportStoppedSearchResultPaths(request: UUID, window: EditorWindow, opened: Int) {
        guard !closing, mainWindow === window, resultPathOpenGeneration == request else {
            return
        }
        window.searchResults.showOperationFeedback("路径打开已停止，已完成 \(opened) 个；结果、输入或光标已改变。")
    }
}
