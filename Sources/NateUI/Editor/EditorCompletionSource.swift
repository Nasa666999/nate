import AppKit
import NateCore

@MainActor
public struct EditorCompletionSource {
    private weak var editor: EditorView?
    private weak var document: DocumentBuffer?
    private weak var window: NSWindow?
    private let revision: UInt64
    private let selection: UUID
    private let documentSelection: UUID
    private let focus: UUID
    private let editing: UUID
    private let rules: UUID
    private let wordRules: UUID

    /// 业务作用：补全后台计算与窗口确认共用同一份正文、选择、规则和实际焦点身份。
    /// 参数说明:
    /// - editor: 请求起点处的真实正文视图。
    /// - window: 当前取得键盘焦点的原生窗口。
    /// 返回：仅在原来源仍实际有效时可发布候选或替换文字的证据。
    init(editor: EditorView, window: NSWindow) {
        self.editor = editor
        document = editor.document
        self.window = window
        revision = editor.document.revision
        selection = editor.selectionGeneration
        documentSelection = editor.document.selectionGeneration
        focus = editor.focusGeneration
        editing = editor.document.editingAuthorityGeneration
        rules = editor.brackets.resource
        wordRules = editor.wordBoundaryGeneration
    }

    /// 业务作用：任何光标、视图、读写权限或词法规则往返变化都撤销旧补全的发布资格。
    /// 参数说明: 无。
    /// 返回：原文件实例及原窗口仍持有同一实际正文选择时为真。
    public func isCurrent() -> Bool {
        // 只比较返回时的位置会让往返切换恢复旧写入权，必须同时复验每项独立代次。
        guard let editor, let document, let window, editor.document === document, editor.window === window,
            NSApp.keyWindow === window, window.firstResponder === editor, document.revision == revision,
            editor.selectionGeneration == selection, document.selectionGeneration == documentSelection,
            editor.focusGeneration == focus, document.editingAuthorityGeneration == editing,
            editor.brackets.resource == rules, editor.wordBoundaryGeneration == wordRules,
            !editor.hasComposition, !document.isEditingSuspended, !document.isReadOnly,
            let state = editor.viewSelectionState, state == document.selectionState
        else {
            return false
        }
        return true
    }
}

extension EditorView {
    /// 业务作用：候选只属于获得键盘输入权的单个普通正文光标。
    /// 参数说明: 无。
    /// 返回：可复验的前缀来源；编辑处于候选、只读、保护或其它窗口时为空。
    public func completionSource() -> EditorCompletionSource? {
        guard let window, let state = viewSelectionState, case .stream = state.shape,
            state.entries.count == 1, state.primary.selection.range.isEmpty,
            state.primary.selection.virtualColumn == 0
        else {
            return nil
        }
        let source = EditorCompletionSource(editor: self, window: window)
        return source.isCurrent() ? source : nil
    }
}
