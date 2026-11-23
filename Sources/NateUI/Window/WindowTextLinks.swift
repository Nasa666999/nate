import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：同一完整链接配置同步全部现有克隆，只撤销链接派生证据，不重置字体和矩形排版权限。
    /// 参数说明:
    /// - settings: 已通过完整协议及容量校验的链接设置。
    /// 返回：各视图采用独立新来源并安排重绘，正文、撤销、选择及缩放保持。
    public func setTextLinks(_ settings: TextLinkSettings) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.textLinkSettings = settings
        }
    }
}
