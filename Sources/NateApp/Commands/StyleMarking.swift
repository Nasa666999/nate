import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：五组样式共用明确的增添、导航、清除与复制语义，普通查找颜色保持独立。
    /// 参数说明:
    /// - style: 用户指定的持久颜色组。
    /// - action: 本次明确的样式操作。
    /// 返回：进入对应实际动作，不改写查找表达式或历史。
    func routeStyleMark(_ style: DocumentMarkStyle, action: StyleMarkAction) {
        switch action {
        case .all: applyDocumentStyle(style, allOccurrences: true)
        case .selection: applyDocumentStyle(style, allOccurrences: false)
        case .next: navigateDocumentMarks(style, backwards: false)
        case .previous: navigateDocumentMarks(style, backwards: true)
        case .clear: clearDocumentStyles([style])
        case .copy: copyDocumentMarks(styles: [style])
        }
    }

    /// 业务作用：样式添加绑定真实文档与实际视图选区，后台匹配不能在光标往返或配置往返后覆盖新颜色。
    /// 参数说明:
    /// - style: 本次增添的独立颜色组。
    /// - allOccurrences: 是否标记全文的所有字面匹配，而非仅当前实际选区。
    /// 返回：完整计划复验后一次添加颜色，不修改正文、书签、输入历史或焦点；失效保留既有状态。
    func applyDocumentStyle(_ style: DocumentMarkStyle, allOccurrences: Bool) {
        guard style != .search, let context = currentMarkEditor(modifying: true) else {
            markFeedback("请先完成当前输入或等待文档保护结束，再添加颜色样式。")
            return
        }
        cancelDocumentMarkCopy()
        // 新样式动作先收回旧任务身份，再取消后台计算；同一执行域内不留旧请求的发布窗口。
        queryGeneration = UUID()
        let generation = queryGeneration
        searchTask?.cancel()
        searchTask = nil
        markSearchGeneration = generation
        styleMarks.pending = generation
        let preferences = styleMarkPreferences
        let configuration = styleMarks.generation
        let snapshot = context.document.buffer.markSnapshot
        let selections = context.editor.viewSelections
        let movement = searchNavigationGeneration
        let input = SearchRequestInput(findWindow)
        let authority = SearchDocumentAuthority(context.document)
        let window = context.window
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor = context.editor] in
            // 真实视图、正文修订、颜色身份与选择纪元必须共同成立，不能沿旧克隆或旧选区重新发布。
            guard let self, let window, !self.closing, !Task.isCancelled,
                self.mainWindow === window, self.queryGeneration == generation,
                self.styleMarks.generation == configuration, self.styleMarkPreferences == preferences,
                input.matches(self.findWindow), self.findWindow?.isEditingInput != true,
                !window.hasMarkedEditorInput, window.editor === editor, editor?.viewSelections == selections,
                self.searchNavigationGeneration == movement, let document = authority.document,
                self.active === document,
                self.documents.contains(where: {
                    $0 === document
                }),
                authority.matches(document), editor?.document === document.buffer,
                !document.buffer.isEditingSuspended, document.buffer.markGeneration == snapshot.generation
            else {
                return false
            }
            return true
        }
        markFeedback("正在添加样式 \(style.rawValue)。")
        searchTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.queryGeneration == generation {
                    self.searchTask = nil
                }
                if self.markSearchGeneration == generation {
                    self.markSearchGeneration = nil
                }
                if self.styleMarks.pending == generation {
                    self.styleMarks.pending = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try StyleMarkPlanning.prepare(
                        snapshot: snapshot,
                        selections: selections,
                        style: style,
                        all: allOccurrences,
                        preferences: preferences,
                        permit: {
                            !Task.isCancelled
                        }
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
                guard current(), let document = authority.document else {
                    if !self.closing, self.queryGeneration == generation, input.matches(self.findWindow) {
                        self.markFeedback("正文、标记或选区已改变，未继续添加旧样式。")
                    }
                    return
                }
                let count = try document.buffer.commitMarks(result.plan)
                self.mainWindow?.refreshEditors()
                self.refreshUI()
                self.markFeedback(
                    "样式 \(style.rawValue) · 本次 \(result.matched) 处 · 保留 \(count) 项。"
                        + (result.unmapped > 0 ? "\(result.unmapped) 个 UTF-16 命中无法无损标记。" : "")
                )
            }
            catch {
                if !self.closing, self.queryGeneration == generation, input.matches(self.findWindow) {
                    self.markFeedback(
                        error is CancellationError || Task.isCancelled
                            ? "样式添加已取消，原颜色保留。" : error.localizedDescription
                    )
                }
            }
        }
    }

    /// 业务作用：仅清除用户指定的颜色组，组外查找标记、其它样式和书签保持原状态。
    /// 参数说明:
    /// - styles: 用户明确要求清除的独立颜色组。
    /// 返回：当前标记计划先失权，随后同步清除所选颜色，不增加正文修订或撤销项。
    func clearDocumentStyles(_ styles: [DocumentMarkStyle]) {
        guard let context = currentMarkEditor(modifying: true) else {
            return
        }
        cancelSearchMarking()
        cancelDocumentMarkCopy()
        let count = Set(styles).reduce(0) {
            $0 + context.document.buffer.clearMarks($1)
        }
        context.window.refreshEditors()
        refreshUI()
        markFeedback("已清除 \(count) 个指定颜色标记，正文和书签保留。")
    }

    /// 业务作用：搜索菜单打开共享标记页，已有输入候选和完整草稿仍由原输入上下文持有。
    /// 参数说明: 无。
    /// 返回：合法上下文显示标记页，未确认输入或缺少文档时不切换页面与焦点。
    func presentMarkPage() {
        guard currentMarkEditor(modifying: false) != nil else {
            return
        }
        presentFind(replacing: false)
        findWindow?.present(selection: nil, page: .mark)
    }
}
