import AppKit

extension EditorWindow {
    /// 业务作用：项目与真实目录各自保留内容，项目视图采用此窗口的停靠或浮动位置。
    /// 参数说明:
    /// - visible: 是否展示项目面板区域。
    /// - selected: 需要显式进入的独立面板索引，空值保留当前面板。
    /// - selecting: 是否明确切换到同侧工具组中的项目标签。
    /// 返回：只改变界面区域与当前面板，不载入定义、不打开引用、不清空目录工作区。
    public func setProjectsVisible(_ visible: Bool, selected: Int? = nil, selecting: Bool = true) {
        if let selected {
            projectPanels.select(selected)
        }
        panelDock.setVisible(.projects, visible, selecting: selecting)
        refreshEditors()
    }
}
