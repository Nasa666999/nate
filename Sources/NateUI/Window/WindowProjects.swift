import AppKit

extension EditorWindow {
    /// 业务作用：项目与真实目录各自保留内容，在左侧可调整区域并列占用高度，不替代搜索结果。
    /// 参数说明:
    /// - visible: 是否展示项目面板区域。
    /// - selected: 需要显式进入的独立面板索引，空值保留当前面板。
    /// 返回：只改变界面区域与当前面板，不载入定义、不打开引用、不清空目录工作区。
    public func setProjectsVisible(_ visible: Bool, selected: Int? = nil) {
        if let selected {
            projectPanels.select(selected)
        }
        projectPanels.isHidden = !visible
        navigationSplit.isHidden = directoryPanel.isHidden && projectPanels.isHidden
        window?.contentView?.layoutSubtreeIfNeeded()
        navigationSplit.adjustSubviews()
        workspaceSplit.adjustSubviews()
        if visible {
            workspaceSplit.setPosition(min(280, workspaceSplit.bounds.width / 3), ofDividerAt: 0)
            if !directoryPanel.isHidden {
                navigationSplit.setPosition(navigationSplit.bounds.height / 2, ofDividerAt: 0)
            }
        }
        refreshEditors()
    }
}
