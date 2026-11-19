import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：保存定义以稳定身份进入运行菜单，绑定冲突只停用组合，选择命令仍先进入实际预览。
    /// 参数说明:
    /// - menu: 当前完整运行菜单。
    /// - root: 已包含全部常规命令与命名宏的根菜单。
    /// 返回：加入当前完整定义与唯一有效原生组合，不执行任何程序。
    func appendRunCommandMenu(to menu: NSMenu, root: NSMenu) {
        guard runCommands.ready, !runCommands.library.commands.isEmpty else {
            return
        }
        menu.addItem(.separator())
        for command in runCommands.library.commands {
            let id = "savedRun:" + command.id.uuidString
            add(menu, command.name, id)
            guard let item = menu.items.last else {
                continue
            }
            item.toolTip = "完整准备实际程序、参数与工作目录，再明确确认执行。"
            if let shortcut = command.shortcut {
                if let conflict = commandShortcutConflict(shortcut, excluding: id, in: root) {
                    item.toolTip = "快捷键未启用，与“" + conflict + "”冲突；菜单仍可预览。"
                }
                else {
                    item.keyEquivalent = NativeKeyboardShortcut.menuKey(shortcut)
                    item.keyEquivalentModifierMask = NativeKeyboardShortcut.modifiers(shortcut)
                }
            }
        }
    }
}
