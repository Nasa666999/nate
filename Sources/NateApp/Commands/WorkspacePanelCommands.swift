import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：为每个实际存在的工具列出完整的停靠和浮动入口。
    /// 参数说明:
    /// - view: 需要加入面板位置子菜单的原生视图菜单。
    /// 返回：工具和位置以固定身份交给统一命令路由。
    func addWorkspacePanelMenus(to view: NSMenu) {
        let entry = NSMenuItem(title: "面板停靠", action: nil, keyEquivalent: "")
        let panels = NSMenu(title: entry.title)
        for panel in WorkspacePanel.allCases {
            let item = NSMenuItem(title: panel.title, action: nil, keyEquivalent: "")
            let placements = NSMenu(title: panel.title)
            for placement in WorkspacePanelPlacement.allCases {
                add(
                    placements,
                    placement.title,
                    "workspacePanelPlacement:\(panel.rawValue):\(placement.rawValue)"
                )
            }
            item.submenu = placements
            panels.addItem(item)
        }
        entry.submenu = panels
        view.addItem(entry)
    }

    /// 业务作用：界面和菜单验证共用固定面板身份与明确方向，未知命令没有移动权限。
    /// 参数说明:
    /// - command: 当前菜单项携带的完整命令身份。
    /// 返回：命令字段完整且合法时交付面板及目标，否则为空。
    func workspacePanelPlacementCommand(_ command: String) -> (WorkspacePanel, WorkspacePanelPlacement)? {
        let fields = command.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "workspacePanelPlacement",
            let panel = WorkspacePanel(rawValue: String(fields[1])),
            let placement = WorkspacePanelPlacement(rawValue: String(fields[2]))
        else {
            return nil
        }
        return (panel, placement)
    }

    /// 业务作用：应用有效面板位置后保护所属窗口的当前布局，不修改工具内容或正文。
    /// 参数说明:
    /// - command: 用户明确选中的停靠方向命令。
    /// 返回：实际应用成功后同步布局保护，输入候选或退出期间保持原位置。
    func applyWorkspacePanelCommand(_ command: String) {
        guard !closing, let window = mainWindow,
            let (panel, placement) = workspacePanelPlacementCommand(command),
            window.moveWorkspacePanel(panel, to: placement)
        else {
            return
        }
        scheduleWorkspaceWindowLayout()
        refreshUI()
    }
}
