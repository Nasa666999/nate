import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：同一窗口的所有克隆按各自文档的语言使用同一规则，活动焦点不改变其它视图的来源。
    /// 参数说明:
    /// - settings: 当前工作区按真实文档身份解析的完整 Tab 设置。
    /// 返回：有明确文档来源的视图采用对应规则，正文、焦点、选择及保存点保持原状。
    public func setTabSettings(_ settings: [UUID: TabSettings]) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView,
                let value = settings[editor.document.id]
            else {
                continue
            }
            editor.tabSettings = value
        }
    }
}
