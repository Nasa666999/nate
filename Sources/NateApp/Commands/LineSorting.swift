import AppKit
import NateCore
import NateUI

@MainActor
final class LineSortingRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?
    var lastOptions = LineSortOptions()
    var succeeded: UUID?

    /// 业务作用：排序独立持有准备身份、确认参数和真实完成证据，不借用查找句柄。
    /// 参数说明: 无。
    /// 返回：尚无正文发布权的初始状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：表单确认只属于原实例和实际选择，模态等待不授予新正文的排序权。
    /// 参数说明: 无。
    /// 返回：确认且原上下文有效时启动完整准备，取消或过期保留正文。
    func chooseLineSort() {
        guard lineSorting.task == nil, let (document, window, editor) = quickFindContext(),
            !document.buffer.isReadOnly
        else {
            return
        }
        let selection = editor.selectionGeneration, original = editor.viewSelections
        // 普通多选和虚拟光标没有连续行范围证据，表单不能先显示一个并不存在的全文或矩形范围。
        guard
            editor.rectangularSelections != nil
                || original.count == 1 && original[0].virtualColumn == 0
        else {
            window.status.stringValue = "普通排序需要一个连续选区；多个目标请使用明确矩形选择。"
            return
        }
        let authority = SearchDocumentAuthority(document)
        let editing = document.buffer.editingAuthorityGeneration
        let input = SearchRequestInput(findWindow)
        let scope =
            editor.rectangularSelections != nil
            ? "矩形：\(original.count) 个行内列目标。零宽矩形从各光标到行尾取键；未选中的折叠行保留原位。"
            : original.count == 1 && original[0].range.isEmpty
                ? "范围：全文实际行，末尾换行产生的空位置不额外参与。"
                : "范围：一个普通连续选区涉及的完整逻辑行。"
        guard let options = LineSortDialog.choose(scope: scope, initial: lineSorting.lastOptions) else {
            return
        }
        // 原正文、权限或输入往返变化后，旧表单不能沿同名标签继续获得写入资格。
        guard let (current, currentWindow, currentEditor) = quickFindContext(),
            current === document, currentWindow === window, currentEditor === editor,
            authority.matches(document), document.buffer.editingAuthorityGeneration == editing,
            editor.selectionGeneration == selection, editor.viewSelections == original,
            input.matches(findWindow)
        else {
            window.status.stringValue = "等待期间正文、选区或输入已改变，请重新选择排序。"
            return
        }
        performLineSort(options)
    }

    /// 业务作用：新的编辑意图或关闭先收回排序发布权，再停止后台计算。
    /// 参数说明: 无。
    /// 返回：当前正文、选择、颜色、书签和历史保持原状。
    func cancelLineSort() {
        lineSorting.generation = UUID()
        lineSorting.task?.cancel()
        lineSorting.task = nil
        lineSorting.succeeded = nil
    }

    /// 业务作用：后台完整取键、比较和构建行事务，全部原控制证据仍有效时一次发布。
    /// 参数说明:
    /// - options: 本次明确选择的完整排序规则。
    /// 返回：已启动动作的身份，不能执行时为空；真实成功身份供串行宏确认，失败不消费历史。
    @discardableResult
    func performLineSort(_ options: LineSortOptions) -> UUID? {
        guard let (document, window, editor) = quickFindContext(), !document.buffer.isReadOnly else {
            return nil
        }
        cancelLineSort()
        cancelColumnInsertion()
        cancelMultipleSelection()
        cancelHistoryAction()
        cancelQuickFind()
        let runtime = lineSorting
        runtime.lastOptions = options
        let request = runtime.generation
        let snapshot = document.buffer.snapshot, marks = document.buffer.markSnapshot
        let selections = editor.viewSelections, rectangular = editor.rectangularSelections != nil
        let zeroWidth = editor.rectangleUsesSuffix
        let selection = editor.selectionGeneration, focus = editor.focusGeneration
        let input = SearchRequestInput(findWindow)
        let authority = SearchDocumentAuthority(document)
        let editing = document.buffer.editingAuthorityGeneration
        let bookmarks = document.buffer.bookmarkSnapshot
        let movement = searchNavigationGeneration, query = queryGeneration
        let recording = macroRecordingGeneration
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled,
                self.lineSorting.generation == request,
                let (source, currentWindow, currentEditor) = self.quickFindContext(),
                source === document, currentWindow === window, currentEditor === editor,
                authority.matches(document), !document.buffer.isReadOnly,
                document.buffer.editingAuthorityGeneration == editing,
                document.buffer.bookmarkGeneration == bookmarks.generation,
                document.buffer.markGeneration == marks.generation,
                editor.selectionGeneration == selection, editor.viewSelections == selections,
                editor.focusGeneration == focus, self.searchNavigationGeneration == movement,
                self.queryGeneration == query, input.matches(self.findWindow)
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
                    try PreparedLineSort(
                        snapshot: snapshot,
                        selections: selections,
                        rectangular: rectangular,
                        zeroWidthRectangle: zeroWidth,
                        options: options,
                        marks: marks,
                        bookmarks: bookmarks
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
                // 全部正文和颜色就绪后才复验发布权，迟到排序不能覆盖新的光标或元数据。
                guard current() else {
                    return
                }
                let changed = try document.buffer.commit(plan.transaction)
                editor.refresh()
                if rectangular {
                    _ = editor.setRectangularSelections(plan.selections, zeroWidth: zeroWidth)
                }
                if self.macroRecording, !self.macroPlaying, self.macroRecordingGeneration == recording {
                    self.appendRecordedMacroAction(.lineSort(options))
                }
                if changed {
                    self.didEdit()
                }
                runtime.succeeded = request
                window.status.stringValue =
                    "行排序已完成，共 \(plan.sourceLines.count) 行。"
                    + (plan.reassignedEndings ? "已重新分配原结束符，保留混合换行字节与空行数量。" : "")
                    + (self.macroRecorder.notice.map {
                        " " + $0
                    } ?? "")
            }
            catch {
                if current() {
                    window.status.stringValue = error.localizedDescription
                }
            }
        }
        window.status.stringValue = "正在完整准备行排序，可从编辑菜单取消…"
        return request
    }
}
