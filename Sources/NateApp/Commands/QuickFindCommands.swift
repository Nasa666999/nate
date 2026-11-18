import AppKit
import NateCore
import NateSearch
import NateUI

enum QuickFindAction: String, Sendable {
    case selectNext = "selectFindNext"
    case selectPrevious = "selectFindPrevious"
    case volatileNext = "volatileFindNext"
    case volatilePrevious = "volatileFindPrevious"

    /// 业务作用：明确区分临时查询与更新当前查找条件的用户意图。
    /// 参数说明: 无。
    /// 返回：临时查找不更新完整查找窗口与历史。
    var isVolatile: Bool {
        self == .volatileNext || self == .volatilePrevious
    }

    /// 业务作用：快捷动作方向独立于查找窗口当前方向选项。
    /// 参数说明: 无。
    /// 返回：上一个匹配动作为反向，其余为正向。
    var backwards: Bool {
        self == .selectPrevious || self == .volatilePrevious
    }
}

extension ApplicationController {
    /// 业务作用：只收回当前快捷查找的导航权，正文修改或退出不能继续发布旧修订的命中。
    /// 参数说明: 无。
    /// 返回：先撤销请求身份再取消实际计算，不误取消随后启动的其它搜索。
    func cancelQuickFind() {
        guard let request = quickFindGeneration else {
            return
        }
        quickFindGeneration = nil
        // 搜索已归更新动作所有时只清除旧登记，不能取消另一动作当前持有的执行权。
        guard queryGeneration == request else {
            return
        }
        queryGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
    }

    /// 业务作用：快捷搜索只接收真正正文焦点，不把查找字段、候选或克隆的旧选择当作来源。
    /// 参数说明: 无。
    /// 返回：工作区、正文、焦点与保护状态均有效时的真实来源，否则为空。
    func quickFindContext() -> (WorkspaceDocument, EditorWindow, EditorView)? {
        // 保护阶段已固定选区元数据，快捷定位也不能在此期间改写它；只读本身仍允许导航。
        guard !closing, let document = active, let window = mainWindow,
            let native = window.window, NSApp.keyWindow === native,
            native.firstResponder === window.editor, window.editor.document === document.buffer,
            let selectionState = window.editor.viewSelectionState,
            selectionState == document.buffer.selectionState,
            !document.closing, !document.buffer.isEditingSuspended,
            !window.hasMarkedEditorInput, findWindow?.isEditingInput != true,
            !window.incrementalSearch.isEditingInput,
            documents.contains(where: {
                $0 === document
            })
        else {
            return nil
        }
        return (document, window, window.editor)
    }

    /// 业务作用：从真实正文选择执行 Select and Find 或 Volatile Find，后台提取与导航分别复验同一来源。
    /// 参数说明:
    /// - action: 是否更新当前条件，以及明确的导航方向。
    /// 返回：完整原文匹配后仅发布一个命中；临时查找保留查询、历史与窗口可见性，过期或取消不移动新光标。
    func quickFind(_ action: QuickFindAction) {
        guard let (document, window, editor) = quickFindContext() else {
            return
        }
        let snapshot = document.buffer.snapshot
        let selections = editor.viewSelections
        let selectionGeneration = editor.selectionGeneration
        let focus = editor.focusGeneration
        let authority = SearchDocumentAuthority(document)
        let base = findWindow?.options ?? searchSettingsState.options
        let fillLimit =
            action.isVolatile
            ? nil : (findWindow?.presentationPreferences ?? searchSettingsState.presentation).fillLimit
        var input = SearchRequestInput(findWindow)
        // 显式快捷动作接管导航，先撤销旧请求及路径定位，再把本次后台任务登记为唯一当前搜索。
        queryGeneration = UUID()
        let generation = queryGeneration
        searchTask?.cancel()
        searchTask = nil
        quickFindGeneration = generation
        resultNavigationGeneration = UUID()
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        cancelSearchResultPathOpen()
        directoryWorkspace?.cancelOpen()
        cancelProjectOpen()
        cancelCompletion()
        cancelIncrementalSearch()
        searchNavigationEvidence = nil
        searchNavigationGeneration = UUID()
        let movement = searchNavigationGeneration
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            // 修订、真实实例、选区与焦点身份共同约束发布；往返离开原光标或窗口也不恢复旧任务权限。
            guard let self, let window, let editor, !self.closing, !Task.isCancelled,
                self.queryGeneration == generation, self.mainWindow === window,
                NSApp.keyWindow === window.window, window.window?.firstResponder === editor,
                window.editor === editor, editor.focusGeneration == focus,
                editor.selectionGeneration == selectionGeneration, editor.viewSelections == selections,
                self.searchNavigationGeneration == movement,
                !window.hasMarkedEditorInput, !window.incrementalSearch.isEditingInput,
                self.findWindow?.isEditingInput != true, input.matches(self.findWindow),
                let source = authority.document, self.active === source,
                self.documents.contains(where: {
                    $0 === source
                }), authority.matches(source),
                editor.document === source.buffer, !source.buffer.isEditingSuspended
            else {
                return false
            }
            return true
        }
        window.status.stringValue = "正在快捷查找…"
        searchTask = Task {
            [weak self, weak editor] in
            guard let self else {
                return
            }
            defer {
                if self.queryGeneration == generation {
                    self.searchTask = nil
                }
                if self.quickFindGeneration == generation {
                    self.quickFindGeneration = nil
                }
            }
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let value = try QuickFindInput(
                        text: snapshot.text,
                        selections: selections,
                        fillLimit: fillLimit
                    )
                    try Task.checkCancellation()
                    return value
                }
                let query = try await withTaskCancellationHandler(
                    operation: {
                        try await preparation.value
                    },
                    onCancel: {
                        preparation.cancel()
                    }
                )
                guard current() else {
                    return
                }
                if !action.isVolatile {
                    let field = self.ensureFindWindow()
                    guard field.useSelectionForFind(query.query) else {
                        throw NateError.message("查找输入仍在编辑，当前条件保留。")
                    }
                    input = SearchRequestInput(self.findWindow)
                }
                guard current() else {
                    return
                }
                var options = SearchOptions()
                let matching = self.findWindow?.options ?? base
                options.query = query.query
                options.caseSensitive = action.isVolatile ? false : matching.caseSensitive
                options.wholeWord = action.isVolatile ? false : matching.wholeWord
                options.wrap = action.isVolatile ? true : matching.wrap
                let requested = options
                let worker = Task.detached(priority: .userInitiated) {
                    try SearchEngine.navigate(
                        in: snapshot,
                        options: requested,
                        selection: query.selection,
                        previous: action.backwards
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
                guard current(), let editor, let source = authority.document else {
                    return
                }
                let selected: ByteRange?
                if let hit = result.hits.first {
                    guard let range = hit.range else {
                        throw NateError.message("快捷命中无法无损定位，原选区保留。")
                    }
                    selected = range
                }
                else {
                    selected = query.expandedWord ? query.selection : nil
                }
                if let selected {
                    source.buffer.selections = [TextSelection(anchor: selected.lower, head: selected.upper)]
                    editor.refresh(reveal: true)
                }
                self.mainWindow?.refreshEditors()
                self.refreshUI()
                self.mainWindow?.status.stringValue = result.hits.isEmpty ? "快捷查找已到达边界或没有匹配。" : "已定位快捷匹配。"
            }
            catch {
                if current() {
                    self.mainWindow?.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    /// 业务作用：快捷菜单只验证上下文与选区形态，不为菜单显示扫描正文或建立查找窗口。
    /// 参数说明:
    /// - id: 稳定快捷查找或取消标识。
    /// 返回：对应动作的实际可用性，其它菜单为空。
    func validateQuickFindMenu(_ id: String) -> Bool? {
        if id == "cancelQuickFind" {
            return quickFindGeneration == queryGeneration && searchTask != nil
        }
        guard QuickFindAction(rawValue: id) != nil else {
            return nil
        }
        guard let (_, _, editor) = quickFindContext() else {
            return false
        }
        return editor.viewSelections.count == 1 && editor.viewSelections.first?.virtualColumn == 0
    }
}
