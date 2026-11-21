import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：全部克隆采用相同的分隔符规则，各视图原选择和正文历史保持独立。
    /// 参数说明:
    /// - settings: 已验证的两端字符与扫描范围。
    /// 返回：当前全部编辑视图同步规则，并撤销等待旧规则的选择任务。
    public func setDelimiterSelectionSettings(_ settings: DelimiterSelectionSettings) {
        for view in editorSplit.arrangedSubviews {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView {
                editor.setDelimiterSelectionSettings(settings)
            }
        }
    }
}
