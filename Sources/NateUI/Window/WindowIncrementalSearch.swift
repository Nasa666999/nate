import AppKit
import NateSearch

extension EditorWindow {
    public var isIncrementalSearchVisible: Bool {
        !incrementalSearch.isHidden
    }

    /// 业务作用：在编辑区上方打开增量栏并恢复独立选项，保持正文可继续编辑。
    /// 参数说明:
    /// - query: 当前选区或光标词的完整填入；为空时保留既有增量输入。
    /// - options: 当前增量查找选项。
    /// 返回：查询字段取得焦点，完整输入一次性交给后台协调，不改正文。
    public func showIncrementalSearch(query: String?, options: IncrementalSearchOptions) {
        incrementalSearch.prepare(query: query, options: options)
        incrementalSearch.isHidden = false
        incrementalHeight?.constant = 68
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(incrementalSearch.input)
        incrementalSearch.publishQuery(force: true)
    }

    /// 业务作用：关闭增量栏时取消未确认全文草稿，把键盘入口交回当前编辑视图。
    /// 参数说明: 无。
    /// 返回：增量区域收起，已确认查询保留，正文与当前命中选择不改变。
    public func hideIncrementalSearch() {
        incrementalSearch.isHidden = true
        incrementalHeight?.constant = 0
        incrementalSearch.input.cancelFullTextEditor()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(editor)
    }
}
