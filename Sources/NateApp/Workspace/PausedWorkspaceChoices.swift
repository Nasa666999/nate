import AppKit
import NateStorage

struct PausedWorkspaceSelection {
    let documents: Bool
    let sidebars: SidebarRecoveryState?
    let authority: PausedSidebarAuthority?
}

extension ApplicationController {
    /// 业务作用：由用户明确选择一份原保留目录，不把排序结果默认当成应覆盖当前工作区的记录。
    /// 参数说明:
    /// - choices: 已完成有界列举的普通保留目录。
    /// 返回：确认的原目录；取消或清单无选择时为空。
    func choosePausedWorkspace(_ choices: [URL]) -> URL? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 500, height: 26))
        popup.addItems(withTitles: choices.map(\.lastPathComponent))
        let alert = NSAlert()
        alert.messageText = "恢复先前保留工作区"
        alert.informativeText = "下一步可选择独立正文副本或项目与目录侧栏。原保留记录继续保留。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "下一步")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
            choices.indices.contains(popup.indexOfSelectedItem)
        else {
            return nil
        }
        return choices[popup.indexOfSelectedItem]
    }

    /// 业务作用：正文追加与侧栏替换分别征求明确选择，覆盖当前未保存项目定义还需单独确认。
    /// 参数说明:
    /// - sidebars: 所选归档中完整有效的侧栏，缺失或不可读时为空。
    /// - warning: 归档侧栏回退或不可用的具体原因。
    /// 返回：用户选择及绑定的当前侧栏证据；任何取消、空选择或侧栏改变均不授权替换。
    func choosePausedContents(_ sidebars: SidebarRecoveryState?, warning: String?)
        -> PausedWorkspaceSelection?
    {
        let authority = pausedSidebarAuthority()
        let body = NSButton(checkboxWithTitle: "加入独立正文副本（不取得原文件写入权）", target: nil, action: nil)
        let sidebar = NSButton(checkboxWithTitle: "替换当前项目和目录侧栏（引用文件保持未打开）", target: nil, action: nil)
        body.state = .on
        sidebar.isEnabled = sidebars != nil && authority != nil
        let currentEmpty =
            authority?.state.projects.allSatisfy {
                $0.workspace == nil
            } == true
            && authority?.state.directory == nil
        sidebar.state = sidebar.isEnabled && currentEmpty ? .on : .off
        let stack = NSStackView(views: [body, sidebar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 60)
        let alert = NSAlert()
        alert.messageText = "选择导入内容"
        alert.informativeText =
            "正文保留原活动顺序、固定、只读、编码、书签和选区。侧栏替换不会自动连接目录或读取项目引用。"
            + (warning.map {
                "\n" + $0
            } ?? "")
        alert.accessoryView = stack
        alert.addButton(withTitle: "导入所选内容")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, body.state == .on || sidebar.state == .on else {
            return nil
        }
        let selected = sidebar.isEnabled && sidebar.state == .on ? sidebars : nil
        if selected != nil
            && projectPanelStates.contains(where: {
                $0.isDirty
            })
        {
            let confirmation = NSAlert()
            confirmation.messageText = "替换当前未保存的项目定义？"
            confirmation.informativeText = "当前三个项目面板中的未保存定义将被所选侧栏替换。请取消并先保存需要保留的定义。正文不会被关闭。"
            confirmation.addButton(withTitle: "取消")
            confirmation.addButton(withTitle: "替换当前侧栏")
            guard confirmation.runModal() == .alertSecondButtonReturn else {
                return nil
            }
        }
        return PausedWorkspaceSelection(
            documents: body.state == .on,
            sidebars: selected,
            authority: authority
        )
    }
}
