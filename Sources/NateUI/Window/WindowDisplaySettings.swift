import AppKit

extension EditorWindow {
    /// 业务作用：同一窗口全部克隆采用用户明确应用的字体与显示选项，各自保留正文来源和选择。
    /// 参数说明:
    /// - font: 已确认可用的原生字体及字号。
    /// - wrapLines: 是否在当前各自视口宽度自动换行。
    /// - showSymbols: 是否显示空白和控制符号。
    /// 返回：所有当前视图重建各自排版，正文、保存点和撤销历史保持原状。
    public func setDisplayOptions(font: NSFont, wrapLines: Bool, showSymbols: Bool) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.font = font
            editor.wrapLines = wrapLines
            editor.showSymbols = showSymbols
            // 字体和宽度改变后，旧矩形像素及待执行剪贴板不能沿用新排版的坐标权限。
            editor.refresh()
        }
    }
}
