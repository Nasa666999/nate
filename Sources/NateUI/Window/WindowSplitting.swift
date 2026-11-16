import AppKit

extension EditorWindow {
    /// 业务作用：克隆视图共享正文，排版、滚动容器和输入法状态分别持有。
    /// 参数说明:
    /// - vertical: 左右分屏为真，上下分屏为假。
    /// 返回：建立第二个编辑视图，不创建第二个磁盘写入者。
    public func splitEditor(vertical: Bool) {
        removeSplit()
        editorSplit.isVertical = vertical
        let clone = EditorView(document: editor.document)
        clone.font = editor.font
        clone.language = editor.language
        clone.showSymbols = editor.showSymbols
        clone.wrapLines = editor.wrapLines
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
        clone.onCommand = {
            [weak self] in self?.onCommand?($0)
        }
        let container = NSScrollView()
        container.hasVerticalScroller = true
        container.hasHorizontalScroller = true
        container.documentView = clone
        editorSplit.addArrangedSubview(container)
        editorSplit.adjustSubviews()
        clone.refresh()
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
        }
    }
}
