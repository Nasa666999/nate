import AppKit
import NateCore
import NateSearch
import NateUI

@MainActor
final class MultipleSelectionRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?
    var options = MultipleSelectionOptions()
    var defaults: UserDefaults?
    var failure: String?
    var session: MultipleSelectionSession?

    /// 业务作用：匹配多选使用独立请求和偏好，不占用完整查找的查询或历史。
    /// 参数说明: 无。
    /// 返回：默认条件与尚未取得原文序列的初始运行状态。
    init() {}
}

@MainActor
final class MultipleSelectionSession {
    private weak var document: WorkspaceDocument?
    private weak var editor: EditorView?
    private let revision: UInt64
    private let selection: UUID
    private let focus: UUID
    let query: String

    /// 业务作用：连续追加保留最初完整表达式，Unicode 折叠后不同长度的命中不会改写下一轮查询。
    /// 参数说明:
    /// - document: 本次多选所属的真实文档。
    /// - editor: 持有这些选区的实际视图。
    /// - query: 最初完整选词或选中文本。
    /// 返回：不持有正文树的轻量序列证据。
    init(document: WorkspaceDocument, editor: EditorView, query: String) {
        self.document = document
        self.editor = editor
        revision = document.buffer.revision
        selection = editor.selectionGeneration
        focus = editor.focusGeneration
        self.query = query
    }

    /// 业务作用：用户改选、换视图、离开焦点或修改正文后，旧表达式不再自动解释新选择。
    /// 参数说明:
    /// - candidate: 当前实际文档。
    /// - view: 当前实际编辑视图。
    /// 返回：真实实例、正文修订、选区和焦点身份均未改变时为真。
    func matches(_ candidate: WorkspaceDocument, view: EditorView) -> Bool {
        candidate === document && view === editor && candidate.buffer.revision == revision
            && view.selectionGeneration == selection && view.focusGeneration == focus
    }
}

extension ApplicationController {
    /// 业务作用：撤销匹配多选的发布资格，用户新光标不能被后台旧选择覆盖。
    /// 参数说明:
    /// - clearSession: 是否同时结束连续多选原文序列，新的同序列请求可保留它。
    /// 返回：先撤销身份再取消计算；取消不会更改正文、查找条件或现有选区。
    func cancelMultipleSelection(clearSession: Bool = true) {
        multipleSelection.generation = UUID()
        multipleSelection.task?.cancel()
        multipleSelection.task = nil
        if clearSession {
            multipleSelection.session = nil
        }
    }

    /// 业务作用：在真实正文焦点执行全部、追加或跳过，完整计划复验后一次更新视图选区。
    /// 参数说明:
    /// - action: 用户明确选择的多选动作。
    /// 返回：独立后台匹配不修改正文或查找历史，过期、取消和超量都保留原选择。
    func selectMatches(_ action: MultipleSelectionAction) {
        guard let (document, window, editor) = quickFindContext() else {
            return
        }
        let runtime = multipleSelection
        let original = editor.viewSelections
        let query = runtime.session?.matches(document, view: editor) == true ? runtime.session?.query : nil
        cancelMultipleSelection(clearSession: false)
        cancelQuickFind()
        cancelIncrementalSearch()
        cancelProjectOpen()
        directoryWorkspace?.cancelOpen()
        resultNavigationGeneration = UUID()
        resultNavigationTask?.cancel()
        cancelCompletion()
        // 多选明确接管当前位置，已在等待中的其它搜索不能随后沿旧导航意图选中另一处正文。
        queryGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        searchNavigationGeneration = UUID()
        searchNavigationEvidence = nil
        let request = runtime.generation
        let revision = document.buffer.revision, selections = editor.selectionGeneration
        let focus = editor.focusGeneration, movement = searchNavigationGeneration,
            queryIdentity = queryGeneration
        let input = SearchRequestInput(findWindow)
        let authority = SearchDocumentAuthority(document)
        let snapshot = document.buffer.snapshot, options = runtime.options
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled,
                self.multipleSelection.generation == request,
                let (source, currentWindow, currentEditor) = self.quickFindContext(),
                source === document, currentWindow === window, currentEditor === editor,
                authority.matches(source), source.buffer.revision == revision,
                editor.selectionGeneration == selections, editor.viewSelections == original,
                editor.focusGeneration == focus,
                self.searchNavigationGeneration == movement, self.queryGeneration == queryIdentity,
                input.matches(self.findWindow)
            else {
                return false
            }
            return true
        }
        runtime.task = Task {
            defer {
                if runtime.generation == request {
                    runtime.task = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PreparedMultipleSelection(
                        snapshot: snapshot,
                        selections: original,
                        query: query,
                        action: action,
                        options: options
                    )
                }
                let plan = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 已提交正文、真实视图、完整输入和导航身份共同约束选区发布，往返变化不恢复旧资格。
                guard current() else {
                    return
                }
                document.buffer.selections = plan.selections
                editor.refresh()
                if action != .all {
                    editor.revealSelection(plan.selections.last)
                }
                editor.onSelection?()
                runtime.session = MultipleSelectionSession(
                    document: document,
                    editor: editor,
                    query: plan.query
                )
                self.refreshUI()
                window.status.stringValue =
                    plan.selections == original ? "没有其它未选匹配，原选区保留。" : "已选择 \(plan.selections.count) 处。"
            }
            catch {
                if current() {
                    window.status.stringValue = error.localizedDescription
                }
            }
        }
        window.status.stringValue = "正在准备匹配多选…"
    }

    /// 业务作用：撤回真实视图中最近建立的一项选择，至少保留一个光标且不产生正文撤销历史。
    /// 参数说明: 无。
    /// 返回：移除最后选区并显示前一个，当前原文序列有效时继续保留其完整查询。
    func removeLastMatchSelection() {
        guard let (document, _, editor) = quickFindContext(), editor.viewSelections.count > 1 else {
            return
        }
        let runtime = multipleSelection
        let query = runtime.session?.matches(document, view: editor) == true ? runtime.session?.query : nil
        cancelMultipleSelection()
        document.buffer.selections = Array(editor.viewSelections.dropLast())
        editor.refresh()
        editor.revealSelection(document.buffer.selections.last)
        editor.onSelection?()
        if let query {
            runtime.session = MultipleSelectionSession(document: document, editor: editor, query: query)
        }
        refreshUI()
    }
}
