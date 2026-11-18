import AppKit
import NateCore
import NateUI

@MainActor
final class ColumnEditingRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?
    var lastValue: ColumnInsertionValue?

    /// 业务作用：列编辑保留独立取消身份和上次明确参数，不把数值表单当成可执行宏。
    /// 参数说明: 无。
    /// 返回：尚无正文发布权的初始运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：显示实际范围和完整数字格式，模态选择不能沿原光标的旧正文直接提交。
    /// 参数说明: 无。
    /// 返回：用户确认且原文档和选区仍有效后启动完整列编辑，取消保留正文与历史。
    func columnEditor() {
        guard columnEditing.task == nil, let (document, window, editor) = quickFindContext(),
            !document.buffer.isReadOnly
        else {
            return
        }
        let original = editor.viewSelections, selection = editor.selectionGeneration
        let editing = document.buffer.editingAuthorityGeneration
        let authority = SearchDocumentAuthority(document)
        let input = SearchRequestInput(findWindow)
        let scope: String
        if original.count == 1, let selected = original.first, selected.range.isEmpty {
            let first = document.buffer.text.lineNumber(at: selected.head)
            scope =
                "范围：第 \(first + 1) 行当前字素列至末行，共 \(document.buffer.text.lineCount - first) 行。"
                + "\n每个完整字形簇计一列，Tab 按四列停靠；短行补空格，Tab 内部按原停靠宽度拆分。"
        }
        else {
            scope = "范围：\(original.count) 个明确选区，按文档从上到下替换；交叠目标归并，虚拟列仅在插入时补空白。"
        }
        guard let value = ColumnEditorDialog.choose(scope: scope, initial: columnEditing.lastValue) else {
            return
        }
        // 原表单确认只属于原实例与原选区，期间的编辑或查找条件往返不能沿同名标签继续提交。
        guard let (current, currentWindow, currentEditor) = quickFindContext(),
            current === document, currentWindow === window, currentEditor === editor,
            authority.matches(document), document.buffer.editingAuthorityGeneration == editing,
            editor.selectionGeneration == selection,
            editor.viewSelections == original, input.matches(findWindow)
        else {
            window.status.stringValue = "表单等待期间正文、选区或输入已改变，请重新打开列编辑器。"
            return
        }
        performColumnInsertion(value)
    }

    /// 业务作用：撤销尚未发布的列事务，新光标和退出保护不能被迟到的数字计划覆盖。
    /// 参数说明: 无。
    /// 返回：先收回请求身份再取消准备；原正文、选区和历史保持原状。
    func cancelColumnInsertion() {
        columnEditing.generation = UUID()
        columnEditing.task?.cancel()
        columnEditing.task = nil
    }

    /// 业务作用：后台完整生成目标、数字、空白和正文，全部证据仍有效时一次发布列编辑。
    /// 参数说明:
    /// - value: 用户明确确认的完整固定文字或数字格式。
    /// 返回：一个可撤销事务与清零后的真实光标；取消、过期、只读或容量不足不提交部分目标。
    func performColumnInsertion(_ value: ColumnInsertionValue) {
        guard let (document, window, editor) = quickFindContext(), !document.buffer.isReadOnly else {
            return
        }
        cancelColumnInsertion()
        cancelMultipleSelection()
        cancelHistoryAction()
        cancelLineSort()
        cancelQuickFind()
        let runtime = columnEditing
        runtime.lastValue = value
        let request = runtime.generation
        let snapshot = document.buffer.snapshot, selections = editor.viewSelections
        let selection = editor.selectionGeneration, focus = editor.focusGeneration
        let movement = searchNavigationGeneration, query = queryGeneration
        let input = SearchRequestInput(findWindow)
        let authority = SearchDocumentAuthority(document)
        let editing = document.buffer.editingAuthorityGeneration
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled,
                self.columnEditing.generation == request,
                let (source, currentWindow, currentEditor) = self.quickFindContext(),
                source === document, currentWindow === window, currentEditor === editor,
                authority.matches(source), !source.buffer.isReadOnly,
                source.buffer.editingAuthorityGeneration == editing,
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
                    try PreparedColumnInsertion(
                        snapshot: snapshot,
                        selections: selections,
                        value: value,
                        tabWidth: 4
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
                // 只在完整计划和原调用上下文同时成立后发布，不能先写前几行再复验剩余目标。
                guard current() else {
                    return
                }
                let changed = try document.buffer.commit(plan.transaction)
                editor.refresh()
                if changed {
                    self.didEdit()
                }
                window.status.stringValue = "列编辑已完成，共 \(plan.count) 个目标。"
            }
            catch {
                if current() {
                    window.status.stringValue = error.localizedDescription
                }
            }
        }
        window.status.stringValue = "正在准备完整列编辑，可从编辑菜单取消…"
    }
}
