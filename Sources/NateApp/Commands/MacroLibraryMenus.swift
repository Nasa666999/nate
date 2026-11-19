import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：命名宏以稳定身份进入实际菜单，恢复后的快捷键仍先检查现有命令冲突。
    /// 参数说明:
    /// - menu: 当前完整宏菜单。
    /// - root: 已包含全部常规命令的菜单根。
    /// 返回：可播放定义进入菜单，冲突绑定只停用快捷键并保留可见说明。
    func appendMacroLibraryMenu(to menu: NSMenu, root: NSMenu) {
        guard macroLibrary.ready, !macroLibrary.definitions.isEmpty else {
            return
        }
        menu.addItem(.separator())
        for definition in macroLibrary.definitions {
            add(menu, definition.name, "savedMacro:" + definition.id.uuidString)
            guard let item = menu.items.last else {
                continue
            }
            item.toolTip = "\(definition.actions.count) 个实际动作；选择后播放，不替换临时录制。"
            if let shortcut = definition.shortcut {
                if let conflict = macroShortcutConflict(shortcut, excluding: definition.id, in: root) {
                    item.toolTip = "快捷键未启用，与“" + conflict + "”冲突。"
                }
                else {
                    item.keyEquivalent = NativeKeyboardShortcut.menuKey(shortcut)
                    item.keyEquivalentModifierMask = macroShortcutModifiers(shortcut)
                }
            }
        }
    }

    /// 业务作用：保存和恢复绑定使用与原生菜单一致的四个修饰键，设备和功能键标记不被当成额外组合。
    /// 参数说明:
    /// - shortcut: 已验证的逻辑组合。
    /// 返回：对应 AppKit 菜单修饰键集合。
    func macroShortcutModifiers(_ shortcut: MacroShortcut) -> NSEvent.ModifierFlags {
        NativeKeyboardShortcut.modifiers(shortcut)
    }

    /// 业务作用：相同原生组合不能覆盖已有菜单动作，包括其它命名宏和系统编辑器命令。
    /// 参数说明:
    /// - shortcut: 待检查的完整组合。
    /// - id: 本次更新的原宏身份，其旧菜单项不构成自冲突。
    /// - root: 可选的正在构建的新菜单，缺省使用实际应用菜单。
    /// 返回：冲突命令的可读名称，没有冲突时为空。
    func macroShortcutConflict(_ shortcut: MacroShortcut, excluding id: UUID, in root: NSMenu? = nil)
        -> String?
    {
        commandShortcutConflict(shortcut, excluding: "savedMacro:" + id.uuidString, in: root)
    }

    /// 业务作用：独立命令库共用实际组合所有者，宏与运行配置不能沿不同检查规则争用同一键位。
    /// 参数说明:
    /// - shortcut: 当前待保存的完整逻辑组合。
    /// - ignored: 本次修改的原稳定命令，其旧绑定不构成自冲突。
    /// - root: 可选的正在构建的新菜单。
    /// 返回：真实冲突所有者的完整名称，无冲突为空。
    func commandShortcutConflict(
        _ shortcut: KeyboardShortcut,
        excluding ignored: String,
        in root: NSMenu? = nil
    ) -> String? {
        if keyboardMap.ready, let resolution = keyboardMap.resolution {
            if let owner = resolution.owners[shortcut], owner != ignored {
                return keyboardMap.catalog.first(where: {
                    $0.id == owner
                })?.title ?? owner
            }
            return nil
        }
        var pending = (root ?? NSApp.mainMenu)?.items ?? []
        while let item = pending.popLast() {
            if let submenu = item.submenu {
                pending.append(contentsOf: submenu.items)
            }
            guard item.representedObject as? String != ignored, !item.keyEquivalent.isEmpty else {
                continue
            }
            if NativeKeyboardShortcut.menu(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                == shortcut
            {
                return item.title
            }
        }
        if let command = CompatibilityShortcut.command(key: shortcut.key, modifiers: shortcut.modifiers) {
            return menuCommandTitle(command, in: root) ?? "编辑器兼容快捷键"
        }
        return nil
    }

    /// 业务作用：未启用的恢复绑定在管理面板可见，用户无需猜测为什么快捷键仍执行常规命令。
    /// 参数说明: 无。
    /// 返回：至多三项简明冲突说明及剩余数量，没有冲突时为空。
    func macroShortcutWarning() -> String? {
        var messages: [String] = []
        for definition in macroLibrary.definitions {
            if let shortcut = definition.shortcut,
                let conflict = macroShortcutConflict(shortcut, excluding: definition.id)
            {
                let name = String(String.UnicodeScalarView(definition.name.unicodeScalars.prefix(60)))
                messages.append(name + "：快捷键与“" + conflict + "”冲突，未启用。")
            }
        }
        guard !messages.isEmpty else {
            return nil
        }
        return messages.prefix(3).joined(separator: "\n")
            + (messages.count > 3 ? "\n另有 \(messages.count - 3) 项冲突。" : "")
    }
}
