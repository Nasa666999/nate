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

    /// 业务作用：所有当前克隆采用明确的全局自动缩进和退格规则，不修改任何既有空白或视觉边缘。
    /// 参数说明:
    /// - settings: 当前完整且合法的输入策略。
    /// 返回：只改变后续按键行为，正文、选择、历史、字体和停靠宽度保持原状。
    public func setIndentationSettings(_ settings: IndentationSettings) {
        for view in editorSplit.arrangedSubviews {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView {
                editor.indentationSettings = settings
            }
        }
    }
}
