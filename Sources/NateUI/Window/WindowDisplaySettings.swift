import AppKit

extension EditorWindow {
    /// 业务作用：参考线只改变各克隆的绘制，不重置临时缩放、真实字体、选择或排版权限。
    /// 参数说明:
    /// - indentation: 是否显示完整缩进内部及空行延续的参考线。
    /// - column: 一至 4096 列的长行参考位置，为空时关闭。
    /// 返回：合法设置同步全部现有视图；非法列保留此前显示并提供原因。
    public func setReferenceGuides(indentation: Bool, column: Int?) {
        if let column, !(1...4096).contains(column) {
            status.stringValue = "长行参考列须为 1 至 4096，原参考线设置保持。"
            return
        }
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.showIndentGuides = indentation
            editor.longLineColumn = column
            editor.referenceGuideStatus = nil
            editor.needsDisplay = true
        }
    }

    /// 业务作用：同一窗口全部克隆采用用户明确应用的字体与显示选项，各自保留正文来源和选择。
    /// 参数说明:
    /// - font: 已确认可用的原生字体及字号。
    /// - wrapLines: 是否在当前各自视口宽度自动换行。
    /// - showSymbols: 是否显示空白和控制符号。
    /// 返回：所有当前视图建立新的字体缩放基准并重建排版，正文、保存点和撤销历史保持原状。
    public func setDisplayOptions(font: NSFont, wrapLines: Bool, showSymbols: Bool) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.setBaseFont(font)
            editor.wrapLines = wrapLines
            editor.showSymbols = showSymbols
            // 字体和宽度改变后，旧矩形像素及待执行剪贴板不能沿用新排版的坐标权限。
            editor.refresh()
        }
    }
}
