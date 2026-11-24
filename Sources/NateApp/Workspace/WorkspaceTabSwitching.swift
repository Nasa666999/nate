import AppKit
import NateUI

enum WorkspaceTabSwitchOrder: String, CaseIterable {
    case tabOrder
    case recentlyUsed

    static let preferenceKey = "tabSwitchOrder"

    /// 业务作用：为窗口菜单显示每种切换顺序。
    /// 参数说明: 无。
    /// 返回：与实际遍历规则一致的用户可读名称。
    var title: String {
        switch self {
        case .tabOrder: return "标签顺序"
        case .recentlyUsed: return "最近使用顺序"
        }
    }
}

@MainActor
final class WorkspaceTabSwitching {
    struct Cycle {
        weak var window: EditorWindow?
        let generation: UUID
        let order: [UUID]
        var selected: UUID
    }

    var visits: [ObjectIdentifier: [UUID]] = [:]
    var cycle: Cycle?
    var preferenceGeneration = UUID()
}

extension ApplicationController {
    /// 业务作用：按实际配置解释标签切换方式，首次使用保留标签顺序。
    /// 参数说明: 无。
    /// 返回：当前方式，无法识别的值使用默认且保留原值。
    var workspaceTabSwitchOrder: WorkspaceTabSwitchOrder {
        guard
            let value = configurationDefaults().object(forKey: WorkspaceTabSwitchOrder.preferenceKey)
                as? String
        else {
            return .tabOrder
        }
        return WorkspaceTabSwitchOrder(rawValue: value) ?? .tabOrder
    }

    /// 业务作用：偏好从“窗口”菜单明确切换，与四空格 Tab 正文输入偏好各自独立。
    /// 参数说明:
    /// - id: 菜单命令和完整排序值。
    /// 返回：识别后使用新遍历顺序并持久保存；无效命令不更新偏好。
    func chooseWorkspaceTabSwitchOrder(_ id: String) {
        guard let order = WorkspaceTabSwitchOrder(rawValue: String(id.dropFirst("tabSwitchOrder:".count))),
            !closing, mainWindow != nil
        else {
            return
        }
        finishWorkspaceTabCycle()
        workspaceTabSwitching.preferenceGeneration = UUID()
        configurationDefaults().set(order.rawValue, forKey: WorkspaceTabSwitchOrder.preferenceKey)
    }

    /// 业务作用：将已成功显示的标签移到所属窗口的访问历史首位。
    /// 参数说明:
    /// - id: 刚显示或结束键盘遍历后保留的文档身份。
    /// - window: 实际持有标签的窗口。
    /// 返回：仅保留当前窗口现存标签的有界历史，其他窗口的克隆不共享访问顺序。
    func rememberWorkspaceTab(_ id: UUID, in window: EditorWindow) {
        let members = Set(workspaceTabIDs(in: window))
        guard members.contains(id) else {
            return
        }
        let key = ObjectIdentifier(window)
        let previous = workspaceTabSwitching.visits[key] ?? []
        workspaceTabSwitching.visits[key] = [id] + previous.filter { $0 != id && members.contains($0) }
    }

    /// 业务作用：结束本轮 Control 遍历后只把最终停留标签记为新访问。
    /// 参数说明: 无。
    /// 返回：旧窗口或已移除标签不能获得访问资格；中途浏览的标签保留原顺序。
    func finishWorkspaceTabCycle() {
        guard let cycle = workspaceTabSwitching.cycle else {
            return
        }
        // 先交回键盘遍历状态，旧窗口或中途已切换的标签不能成为后续遍历起点。
        workspaceTabSwitching.cycle = nil
        if let window = cycle.window, isWorkspaceWindowAvailable(window),
            window.editor.document.id == cycle.selected
        {
            rememberWorkspaceTab(cycle.selected, in: window)
        }
    }

    /// 业务作用：按当前选择的顺序在所属窗口循环浏览标签。
    /// 参数说明:
    /// - forward: 正向切换，反向使用同一顺序。
    /// - event: 真实键盘事件，菜单单击时为空。
    /// 返回：有效激活后共享原正文与历史；持续按住 Control 时固定本轮遍历顺序。
    func cycleTab(forward: Bool, event: NSEvent? = nil) {
        guard let window = mainWindow, let activeID, !closing else {
            return
        }
        let tabs = workspaceTabIDs(in: window)
        guard tabs.count > 1, tabs.contains(activeID) else {
            finishWorkspaceTabCycle()
            return
        }
        let usingRecent = workspaceTabSwitchOrder == .recentlyUsed
        let holdingControl =
            usingRecent && event?.type == .keyDown && event?.modifierFlags.contains(.control) == true
            && event?.windowNumber == window.window?.windowNumber
        var cycle: WorkspaceTabSwitching.Cycle?
        if holdingControl, let pending = workspaceTabSwitching.cycle, pending.window === window,
            pending.selected == activeID, pending.generation == window.tabOrderIdentity
        {
            cycle = pending
        }
        else {
            finishWorkspaceTabCycle()
        }
        let order: [UUID]
        if let cycle {
            order = cycle.order
        }
        else if usingRecent {
            let members = Set(tabs)
            var found: Set<UUID> = []
            let history = workspaceTabSwitching.visits[ObjectIdentifier(window)] ?? []
            order = ([activeID] + history + tabs).filter {
                members.contains($0) && found.insert($0).inserted
            }
        }
        else {
            order = tabs
        }
        guard let index = order.firstIndex(of: activeID) else {
            return
        }
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        guard activate(next, in: window, recordTabVisit: !holdingControl) else {
            finishWorkspaceTabCycle()
            return
        }
        if holdingControl {
            // 中途只更新本轮光标，直到 Control 释放才把最终标签发布到最近使用顺序。
            workspaceTabSwitching.cycle = WorkspaceTabSwitching.Cycle(
                window: window,
                generation: window.tabOrderIdentity,
                order: order,
                selected: next
            )
        }
    }
}
