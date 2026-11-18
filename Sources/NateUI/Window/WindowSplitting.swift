import AppKit

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
            removeSplit()
        }
        if let primary = scroll.documentView as? EditorView, primary.document.id == id {
            editor = primary
            window?.makeFirstResponder(primary)
        }
        scrollPositions.removeValue(forKey: id)
    }

    /// 业务作用：克隆视图共享正文，排版、滚动容器和输入法状态分别持有。
    /// 参数说明:
    /// - vertical: 左右分屏为真，上下分屏为假。
    /// 返回：建立第二个编辑视图，不创建第二个磁盘写入者。
    public func splitEditor(vertical: Bool) {
        removeSplit()
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
        clone.language = editor.language
        clone.userLanguage = editor.userLanguage
        clone.onStatus = {
            [weak self] message in self?.status.stringValue = message
        }
        clone.onOpenURLs = {
            [weak self] urls in self?.onOpenURLs?(urls)
        }
        clone.showSymbols = editor.showSymbols
        clone.wrapLines = editor.wrapLines
        clone.copyLineWithoutSelection = editor.copyLineWithoutSelection
        clone.adaptClipboardLineEndings = editor.adaptClipboardLineEndings
        clone.onClipboardCapture = {
            [weak self] in self?.onClipboardCapture?($0)
        }
        clone.onClipboardPaste = {
            [weak self] in self?.onClipboardPaste?($0, $1)
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

    /// 业务作用：关闭克隆只释放该视图，原文档与保存任务继续有效。
    /// 参数说明: 无。
    /// 返回：恢复单视图并保留原窗口编辑器。
    public func removeSplit() {
        for view in editorSplit.arrangedSubviews.dropFirst() {
            (view as? NSScrollView)?.documentView.map {
                ($0 as? EditorView)?.finishComposition()
            }
            editorSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let primary = scroll.documentView as? EditorView {
            editor = primary
            window?.makeFirstResponder(primary)
        }
    }
}
