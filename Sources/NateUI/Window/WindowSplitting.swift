import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：关闭文档时释放它的全部克隆视图，避免已移出工作区的正文继续接受输入。
    /// 参数说明:
    /// - id: 已完成持久化并移出工作区的文档身份。
    /// 返回：克隆被释放，主视图等待工作区绑定下一文档。
    public func retireDocument(_ id: UUID) {
        let secondaryContains = editorSplit.arrangedSubviews.dropFirst().contains {
            (($0 as? NSScrollView)?.documentView as? EditorView)?.document.id == id
        }
        if secondaryContains {
            guard removeSplit() else {
                return
            }
        }
        if let primary = scroll.documentView as? EditorView, primary.document.id == id {
            editor = primary
            window?.makeFirstResponder(primary)
        }
        tabViewPositions.removeValue(forKey: id)
    }

    /// 业务作用：克隆视图共享正文，排版、滚动容器和输入法状态分别持有。
    /// 参数说明:
    /// - vertical: 左右分屏为真，上下分屏为假。
    /// 返回：建立继承当前字体缩放的第二个编辑视图，不创建第二个磁盘写入者。
    public func splitEditor(vertical: Bool) {
        guard removeSplit() else {
            return
        }
        editorSplit.isVertical = vertical
        let clone = EditorView(document: editor.document)
        clone.selectedTextHighlightContext = {
            [weak self, weak clone] in
            guard let self, let clone else {
                return nil
            }
            return self.selectedTextContext(for: clone)
        }
        clone.font = editor.font
        clone.copyFontZoom(from: editor)
        clone.setWordBoundaries(editor.wordBoundaries)
        clone.setDelimiterSelectionSettings(editor.delimiterSelectionSettings)
        clone.tabSettings = editor.tabSettings
        clone.indentationSettings = editor.indentationSettings
        clone.pairInsertionSettings = editor.pairInsertionSettings
        clone.language = editor.language
        clone.userLanguage = editor.userLanguage
        clone.editorTheme = editor.editorTheme
        clone.showIndentGuides = editor.showIndentGuides
        clone.showModificationHistory = editor.showModificationHistory
        clone.textLinkSettings = editor.textLinkSettings
        clone.onOpenTextLink = editor.onOpenTextLink
        clone.longLineColumn = editor.longLineColumn
        clone.onStatus = {
            [weak self] message in self?.status.stringValue = message
        }
        clone.onOpenURLs = {
            [weak self] urls in self?.onOpenURLs?(urls)
        }
        clone.showSymbols = editor.showSymbols
        clone.wrapLines = editor.wrapLines
        clone.usesDefaultKeyboardRoutes = editor.usesDefaultKeyboardRoutes
        clone.copyLineWithoutSelection = editor.copyLineWithoutSelection
        clone.adaptClipboardLineEndings = editor.adaptClipboardLineEndings
        clone.clipboardMarkupDecoder = editor.clipboardMarkupDecoder
        clone.onClipboardCapture = {
            [weak self] in self?.onClipboardCapture?($0)
        }
        clone.onClipboardPaste = {
            [weak self] in self?.onClipboardPaste?($0, $1)
        }
        clone.onClipboardCopy = {
            [weak self, weak clone] cutting, line in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onClipboardCopy?(cutting, line)
        }
        clone.onChange = {
            [weak self, weak clone] in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onEdit?()
            (self.scroll.documentView as? EditorView)?.refresh()
        }
        clone.onSelection = {
            [weak self, weak clone] in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onCommand?("selectionChanged")
        }
        clone.onTextInput = {
            [weak self, weak clone] text in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onTextInput?(text)
        }
        clone.onPairInput = {
            [weak self, weak clone] command in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onPairInput?(command)
        }
        clone.onCompletionInput = {
            [weak self, weak clone] command in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onCompletionInput?(command)
        }
        clone.onEditorCommand = {
            [weak self, weak clone] command in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onEditorCommand?(command)
        }
        clone.onCommand = {
            [weak self] in self?.onCommand?($0)
        }
        clone.onFocus = {
            [weak self, weak clone] in
            guard let self, let clone else {
                return
            }
            self.editor = clone
            self.onCommand?("selectionChanged")
        }
        let container = NSScrollView(frame: editorSplit.bounds)
        container.hasVerticalScroller = true
        container.hasHorizontalScroller = true
        container.documentView = clone
        editorSplit.addArrangedSubview(container)
        editorSplit.adjustSubviews()
        let extent = vertical ? editorSplit.bounds.width : editorSplit.bounds.height
        editorSplit.setPosition(max(1, extent / 2), ofDividerAt: 0)
        clone.refresh()
        if let primary = editorSplit.arrangedSubviews.first as? NSScrollView {
            scrollSynchronization.connect(primary: primary, secondary: container)
        }
    }

    /// 业务作用：剪贴板选项在同一窗口的独立克隆之间一致生效，不能留下旧视图的隐式换行规则。
    /// 参数说明:
    /// - copyLine: 无普通选区是否复制和剪切主光标所在行。
    /// - adaptEndings: 粘贴时是否明确适配插入内容的换行。
    /// 返回：所有当前编辑视图采用新规则，等待旧规则的动作先失权。
    public func setClipboardOptions(copyLine: Bool, adaptEndings: Bool) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.cancelClipboardOperation()
            editor.copyLineWithoutSelection = copyLine
            editor.adaptClipboardLineEndings = adaptEndings
        }
    }

    /// 业务作用：完整自定义路由取得按键身份后关闭旧兼容入口，删除绑定不能留下隐藏执行路径。
    /// 参数说明:
    /// - active: 当前是否仍由编辑器内置兼容规则分发。
    /// 返回：同一窗口所有克隆采用一致规则，新克隆继承当前状态。
    public func setDefaultKeyboardRoutes(active: Bool) {
        for view in editorSplit.arrangedSubviews {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView {
                editor.usesDefaultKeyboardRoutes = active
            }
        }
    }

    /// 业务作用：关闭克隆只释放该视图，原文档与保存任务继续有效。
    /// 参数说明: 无。
    /// 返回：全部候选完成后恢复单视图时为真；任一失败保留原全部视图并为假。
    @discardableResult
    public func removeSplit() -> Bool {
        // 先完整检查所有待移除视图，不能移除第一项之后才发现另一候选无法提交。
        for view in editorSplit.arrangedSubviews.dropFirst() {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView,
                !editor.finishComposition()
            {
                return false
            }
        }
        // 所有候选已经安全完成，先撤销旧克隆的滚动资格，再移除其原生视图。
        scrollSynchronization.disconnect()
        for view in editorSplit.arrangedSubviews.dropFirst() {
            editorSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let primary = scroll.documentView as? EditorView {
            editor = primary
            window?.makeFirstResponder(primary)
        }
        return true
    }

    /// 业务作用：关闭、保护和保存固定目标文档在全部可见克隆中的最后候选，不能只检查活动视图。
    /// 参数说明:
    /// - documentID: 明确目标文档，省略时检查全部当前视图。
    /// 返回：全部相关候选确认成功或不存在时为真；任一失败保留相关视图并为假。
    public func finishCompositions(documentID: UUID? = nil) -> Bool {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView,
                documentID == nil || editor.document.id == documentID
            else {
                continue
            }
            // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
            guard editor.finishComposition() else {
                return false
            }
        }
        return true
    }
}
