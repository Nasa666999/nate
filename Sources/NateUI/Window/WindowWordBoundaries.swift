import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：窗口全部克隆采用同一词字符偏好，各自保留实际选区和后台匹配身份。
    /// 参数说明:
    /// - settings: 本次明确发布的完整词规则。
    /// 返回：全部当前视图同步后续选词规则，正文和撤销历史保持原状。
    public func setWordBoundaries(_ settings: WordBoundarySettings) {
        for view in editorSplit.arrangedSubviews {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView {
                editor.setWordBoundaries(settings)
            }
        }
    }
}
