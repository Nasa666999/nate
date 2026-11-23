import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：完整主题同步同一窗口全部克隆，各视图保留自己的正文、选择、滚动和缩放。
    /// 参数说明:
    /// - theme: 已编码并确认稳定身份的完整主题，为空时恢复系统与原资源样式。
    /// 返回：各视图的旧布局权限撤销，新主题完整生效，不修改正文与保存点。
    public func setEditorTheme(_ theme: EditorThemeSnapshot?) {
        for view in editorSplit.arrangedSubviews {
            guard let scroll = view as? NSScrollView, let editor = scroll.documentView as? EditorView else {
                continue
            }
            editor.editorTheme = theme
            scroll.backgroundColor = editor.presentationBackground
        }
    }
}
