import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：菜单读取当前工具面板实际位置，和窗口恢复共用同一来源。
    /// 参数说明:
    /// - panel: 此窗口的工具身份。
    /// 返回：正在使用的停靠或浮动位置。
    public func workspacePanelPlacement(_ panel: WorkspacePanel) -> WorkspacePanelPlacement {
        panelDock.placement(of: panel)
    }

    /// 业务作用：移动面板保持原工具对象，并保护结果筛选尚未确认的输入。
    /// 参数说明:
    /// - panel: 当前窗口内用户明确选择的工具。
    /// - placement: 目标停靠边或浮动方式。
    /// 返回：位置可以交接时为真；结果输入仍未确认时保留实际容器。
    @discardableResult
    public func moveWorkspacePanel(_ panel: WorkspacePanel, to placement: WorkspacePanelPlacement) -> Bool {
        guard panel != .results || !searchResults.isEditingInput else {
            status.stringValue = "请先确认或取消结果筛选输入，再移动结果面板。"
            return false
        }
        if panelDock.placement(of: panel) != placement {
            // 搜索结果的原按钮与位置依赖旧容器，移动后撤销等待中的视觉动作。
            if panel == .results {
                resultGeneration = UUID()
            }
            panelDock.move(panel, to: placement)
            refreshEditors()
        }
        return true
    }

    /// 业务作用：浮动标题栏和窗口命令共用各工具原有的可见性入口。
    /// 参数说明:
    /// - panel: 当前窗口内用户操作的工具。
    /// - visible: 是否显示。
    /// 返回：执行该面板原有的输入保护及布局更新。
    public func setWorkspacePanelVisible(_ panel: WorkspacePanel, _ visible: Bool) {
        switch panel {
        case .directory: setDirectoryVisible(visible)
        case .projects: setProjectsVisible(visible)
        case .structure: setStructureVisible(visible)
        case .results: setResultsVisible(visible)
        }
    }

    /// 业务作用：从浮动工具实际打开文件或激活标签后，将下一次正文输入交回所属原生编辑窗口。
    /// 参数说明: 无。
    /// 返回：原键盘窗口确属当前浮动工具时交接焦点。
    public func restoreEditorFocusFromFloatingPanel() {
        if panelDock.ownsFloatingWindow(NSApp.keyWindow) {
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
