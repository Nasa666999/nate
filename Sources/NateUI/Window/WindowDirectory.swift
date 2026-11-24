import AppKit

extension EditorWindow {
    /// 业务作用：目录侧栏使用当前停靠设置和独立内容，正文视图按实际剩余区域布局。
    /// 参数说明:
    /// - visible: 是否展示真实目录工作区。
    /// - selecting: 是否明确切换到同侧工具组中的目录标签。
    /// 返回：侧栏显示或隐藏，正文只更新可用宽度，不移动焦点和选区。
    public func setDirectoryVisible(_ visible: Bool, selecting: Bool = true) {
        panelDock.setVisible(.directory, visible, selecting: selecting)
        refreshEditors()
    }
}
