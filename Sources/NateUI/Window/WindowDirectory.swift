import AppKit

extension EditorWindow {
    /// 业务作用：目录侧栏独立占用左侧可调整空间，正文克隆和右侧结构面板保留各自布局。
    /// 参数说明:
    /// - visible: 是否展示真实目录工作区。
    /// 返回：侧栏显示或隐藏，正文只更新可用宽度，不移动焦点和选区。
    public func setDirectoryVisible(_ visible: Bool) {
        directoryPanel.isHidden = !visible
        window?.contentView?.layoutSubtreeIfNeeded()
        workspaceSplit.adjustSubviews()
        if visible {
            workspaceSplit.setPosition(min(280, workspaceSplit.bounds.width / 3), ofDividerAt: 0)
        }
        refreshEditors()
    }
}
