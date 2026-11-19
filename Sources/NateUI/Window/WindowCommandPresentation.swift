import AppKit

extension EditorWindow {
    /// 业务作用：工具栏提示沿实际命令绑定更新，清空或改键后不继续展示过期的默认组合。
    /// 参数说明:
    /// - descriptions: 当前稳定命令的完整中文名称和实际启用组合。
    /// 返回：现有工具按钮的悬停与辅助功能名称同步更新，不改变焦点或执行命令。
    public func setCommandTooltips(_ descriptions: [String: String]) {
        for view in toolbarStack.arrangedSubviews {
            guard let button = view as? NSButton, let id = button.identifier?.rawValue,
                let description = descriptions[id]
            else {
                continue
            }
            button.toolTip = description
            button.setAccessibilityLabel(description)
        }
    }
}
