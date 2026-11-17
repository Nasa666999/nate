import AppKit
import NateCore
import NateSearch
import NateUI

@MainActor
final class IncrementalSearchOrigin {
    weak var buffer: DocumentBuffer?
    weak var editor: EditorView?
    let revision: UInt64
    let selection: ByteRange
    var lastPublished: [TextSelection]?
    let originalSelections: [TextSelection]

    /// 业务作用：保留增量细化查询的原始光标，不把上一轮短匹配末端当成下一轮输入起点。
    /// 参数说明:
    /// - buffer: 原正文实例。
    /// - editor: 原焦点视图。
    /// - selections: 打开增量栏时的实际选区。
    /// 返回：不延长文档或视图生命周期的起点证据。
    init(buffer: DocumentBuffer, editor: EditorView, selections: [TextSelection]) {
        self.buffer = buffer
        self.editor = editor
        revision = buffer.revision
        originalSelections = selections
        let start = selections.first?.range.lower ?? 0
        selection = ByteRange(start, start)
    }

    /// 业务作用：正文、视图或用户光标变化后重新固定起点，同一匹配的继续细化仍从原起点搜索。
    /// 参数说明:
    /// - buffer: 当前正文。
    /// - editor: 当前视图。
    /// - selections: 当前视图的完整选区。
    /// 返回：仅原实例、修订和实际选区仍属于此增量会话时为真。
    func matches(buffer: DocumentBuffer, editor: EditorView, selections: [TextSelection]) -> Bool {
        self.buffer === buffer && self.editor === editor && revision == buffer.revision
            && selections == (lastPublished ?? originalSelections)
    }
}

extension ApplicationController {
    /// 业务作用：恢复增量栏自己的少量选项，完整查找窗口的设置保持独立。
    /// 参数说明:
    /// - defaults: 当前应用的偏好存储，独立运行的窗口不自动取得该存储。
    /// 返回：大小写、全词和循环选项进入内存，缺失循环设置默认开启。
    func loadIncrementalOptions(from defaults: UserDefaults) {
        incrementalDefaults = defaults
        incrementalOptions.caseSensitive = defaults.bool(forKey: "incrementalSearch.caseSensitive")
        incrementalOptions.wholeWord = defaults.bool(forKey: "incrementalSearch.wholeWord")
        incrementalOptions.wrap =
            defaults.object(forKey: "incrementalSearch.wrap") == nil
            || defaults.bool(forKey: "incrementalSearch.wrap")
    }

    /// 业务作用：保存用户明确改变的增量选项，不保存候选文本或改动正文状态。
    /// 参数说明:
    /// - options: 增量栏当前完整选项。
    /// 返回：内存选项立即生效，已装配的应用偏好存储记录三个布尔值。
    func saveIncrementalOptions(_ options: IncrementalSearchOptions) {
        incrementalOptions = options
        incrementalDefaults?.set(options.caseSensitive, forKey: "incrementalSearch.caseSensitive")
        incrementalDefaults?.set(options.wholeWord, forKey: "incrementalSearch.wholeWord")
        incrementalDefaults?.set(options.wrap, forKey: "incrementalSearch.wrap")
    }

    /// 业务作用：打开编辑区顶部增量栏，按实际焦点视图取得允许的完整短选区或光标词。
    /// 参数说明: 无。
    /// 返回：复用可见查询，首次打开时填入允许的原文；缺少活动文档或退出保护期间不建立新发布权。
    func showIncrementalSearch() {
        // 增量查找只能绑定仍存在的当前视图，不能由旧活动身份推断新的正文目标。
        guard !closing, let window = mainWindow, let document = active,
            window.editor.document === document.buffer
        else {
            return
        }
        // 正文候选仍归原生输入上下文，打开搜索栏不能借焦点切换提前提交它。
        guard !window.hasMarkedEditorInput else {
            window.status.stringValue = "请先确认或取消正文候选，再打开增量查找。"
            return
        }
        // 再次进入只复用当前查询，不能把正文匹配或尚未确认的候选替换成另一份输入。
        if window.isIncrementalSearchVisible {
            // 候选或全文草稿仍持有输入上下文，重复快捷键不能通过焦点转交提交它。
            guard !window.incrementalSearch.isEditingInput else {
                return
            }
            window.window?.makeFirstResponder(window.incrementalSearch.input)
            window.incrementalSearch.publishQuery(force: true)
            return
        }
        cancelIncrementalSearch(resetOrigin: true)
        incrementalOrigin = IncrementalSearchOrigin(
            buffer: document.buffer,
            editor: window.editor,
            selections: window.editor.viewSelections
        )
        do {
            let context = try SearchPresentation.context(
                text: document.buffer.text,
                selections: window.editor.viewSelections,
                preferences: findWindow?.presentationPreferences ?? searchSettingsState.presentation
            )
            window.showIncrementalSearch(query: context.query, options: incrementalOptions)
        }
        catch {
            window.status.stringValue = error.localizedDescription
        }
    }

    /// 业务作用：撤销旧增量请求的光标发布权，关闭或更换正文时同时丢弃原起点。
    /// 参数说明:
    /// - resetOrigin: 是否结束原文档和视图的细化会话。
    /// 返回：旧计算可自行收束，迟到完成不能选择正文或清除新任务句柄。
    func cancelIncrementalSearch(resetOrigin: Bool = false) {
        // 请求身份先失效，旧任务即使已经完成计算，也不能在随后取得主执行域时更新光标。
        incrementalTask?.cancel()
        incrementalTask = nil
        incrementalGeneration = UUID()
        if resetOrigin {
            incrementalOrigin = nil
        }
    }

    /// 业务作用：关闭增量界面前先撤销后台导航资格，再交还正文焦点。
    /// 参数说明: 无。
    /// 返回：当前查询保留，旧任务与未确认全文草稿都不能在关闭后重新导航。
    func closeIncrementalSearch() {
        // 先撤销发布权再解除输入界面，焦点变化产生的回调不能让旧查询重新取得选择权限。
        cancelIncrementalSearch(resetOrigin: true)
        mainWindow?.hideIncrementalSearch()
    }

    /// 业务作用：在后台定位单个增量命中，发布时复验查询、正文实例、修订、视图、光标及候选状态。
    /// 参数说明:
    /// - query: 完整已确认查询。
    /// - options: 增量栏自己的字面匹配选项。
    /// - previous: 显式导航方向；为空时从会话原光标细化当前输入。
    /// 返回：匹配可见且查询字段保持焦点，取消或证据变化不移动新光标，不改正文或撤销历史。
    func searchIncrementally(_ query: String, options: IncrementalSearchOptions, previous: Bool? = nil) {
        cancelIncrementalSearch()
        guard !closing, let window = mainWindow, window.isIncrementalSearchVisible,
            let document = active, window.editor.document === document.buffer
        else {
            return
        }
        let bar = window.incrementalSearch
        // 候选可能来自另一克隆；共享正文的只读导航同样不能改动候选所依附的选区。
        guard !window.hasMarkedEditorInput else {
            bar.feedback.stringValue = "请先确认或取消正文候选，再继续查找。"
            return
        }
        // 关闭、重新解释或保护动作可能已经固定恢复元数据，增量导航不能再改变这份光标状态。
        guard !document.buffer.isEditingSuspended else {
            bar.feedback.stringValue = "文档正在完成保护动作，请稍后继续查找。"
            return
        }
        // 未确认候选不属于完整查询，按钮和程序入口都不能把它提交给搜索引擎。
        guard !bar.isEditingInput, !bar.input.hasMarkedInput,
            bar.query.utf8.elementsEqual(query.utf8), bar.options == options
        else {
            return
        }
        // 增量输入接管当前导航意图，旧完整查找和结果读取不能在等待后抢回光标。
        searchTask?.cancel()
        searchTask = nil
        queryGeneration = UUID()
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        resultNavigationGeneration = UUID()
        searchNavigationEvidence = nil
        let editor = window.editor
        let buffer = document.buffer
        let snapshot = buffer.snapshot
        let selections = editor.viewSelections
        if incrementalOrigin?.matches(buffer: buffer, editor: editor, selections: selections) != true {
            incrementalOrigin = IncrementalSearchOrigin(
                buffer: buffer,
                editor: editor,
                selections: selections
            )
        }
        let origin = incrementalOrigin
        let selection =
            previous == nil
            ? origin?.selection ?? ByteRange(0, 0) : selections.first?.range ?? ByteRange(0, 0)
        guard !query.isEmpty else {
            bar.feedback.stringValue = "输入查找内容。"
            return
        }
        let generation = incrementalGeneration
        let movement = searchNavigationGeneration
        let authority = SearchDocumentAuthority(document)
        let requested = options.searchOptions(query: query)
        bar.feedback.stringValue = "正在查找…"
        incrementalTask = Task {
            [weak self, weak editor] in
            guard let self else {
                return
            }
            defer {
                if generation == self.incrementalGeneration {
                    self.incrementalTask = nil
                }
            }
            guard generation == self.incrementalGeneration, !Task.isCancelled else {
                return
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try SearchEngine.navigate(
                        in: snapshot,
                        options: requested,
                        selection: selection,
                        previous: previous == true
                    )
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                try Task.checkCancellation()
                guard !self.closing, generation == self.incrementalGeneration,
                    window.isIncrementalSearchVisible, self.mainWindow === window,
                    bar.query.utf8.elementsEqual(query.utf8), bar.options == options
                else {
                    return
                }
                // 相同 UUID 或相同查询不足以导航；移动光标、换视图、重开文档及保护态都会撤销原位置证据。
                guard movement == self.searchNavigationGeneration,
                    let editor, window.editor === editor, editor.document === buffer,
                    let current = self.active, authority.matches(current), current.buffer === buffer,
                    !buffer.isEditingSuspended, !window.hasMarkedEditorInput,
                    editor.viewSelections == selections
                else {
                    bar.feedback.stringValue = "文档或光标已改变，请继续查找。"
                    return
                }
                // 候选通知可能尚未送达拥有者，直接复验输入上下文并在确认后保留一次完整查询。
                guard !bar.isEditingInput else {
                    bar.deferQueryUntilConfirmed()
                    return
                }
                guard let hit = result.hits.first else {
                    bar.feedback.stringValue = "已到达边界或没有匹配。"
                    return
                }
                // 不可映射的 UTF-16 坐标不能代替为邻近正文范围，选择只接受完整 UTF-8 端点证据。
                guard let range = hit.range else {
                    throw NateError.message("命中无法无损定位，请调整完整查询。")
                }
                buffer.selections = [TextSelection(anchor: range.lower, head: range.upper)]
                editor.refresh(reveal: true)
                origin?.lastPublished = editor.viewSelections
                bar.feedback.stringValue = "已定位匹配。"
                window.refreshEditors()
                self.refreshUI()
            }
            catch {
                if generation == self.incrementalGeneration, window.isIncrementalSearchVisible,
                    !window.hasMarkedEditorInput,
                    bar.query.utf8.elementsEqual(query.utf8), bar.options == options,
                    !bar.isEditingInput, !bar.input.hasMarkedInput
                {
                    bar.feedback.stringValue =
                        error is CancellationError ? "已取消。" : error.localizedDescription
                }
            }
        }
    }
}
