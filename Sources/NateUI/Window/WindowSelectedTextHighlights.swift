import AppKit

extension EditorWindow {
    /// 业务作用：窗口从当前实际活动视图分配智能高亮来源，另一视图仅在用户启用时共享表达式。
    /// 参数说明:
    /// - target: 将要显示临时高亮的真实正文视图。
    /// 返回：工作区、候选和视图权限均成立时提供来源与设置，否则为空。
    func selectedTextContext(for target: EditorView) -> SelectedTextHighlightContext? {
        guard let settings = selectedTextHighlightSettings?(target), settings.options.enabled,
            !hasMarkedEditorInput,
            target === editor || settings.options.anotherView,
            target.window === window, editor.window === window,
            editorSplit.arrangedSubviews.contains(where: {
                ($0 as? NSScrollView)?.documentView === target
            })
        else {
            return nil
        }
        return SelectedTextHighlightContext(source: editor, settings: settings)
    }

    /// 业务作用：选择、配置或候选状态变化后刷新所有实际视图的独立智能图层，不移动焦点或视口。
    /// 参数说明: 无。
    /// 返回：当前与克隆视图分别调度自己的视口匹配，已失权图层立即清除。
    public func refreshSelectedTextHighlights() {
        for container in editorSplit.arrangedSubviews {
            if let view = (container as? NSScrollView)?.documentView as? EditorView {
                view.prepareSelectedTextHighlights()
            }
        }
    }
}
