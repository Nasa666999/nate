import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
struct KeyboardCommandEntry {
    let id: String
    let title: String
    let category: String
    var defaults: [KeyboardShortcut]
    var items: [NSMenuItem]
    let managedElsewhere: Bool
}

extension ApplicationController {
    /// 业务作用：实际菜单提供唯一命令目录，配置只引用已登记身份，编码列表重排不能改变持久化绑定语义。
    /// 参数说明:
    /// - root: 尚未安装用户覆盖的完整默认菜单。
    /// 返回：稳定目录与原生执行入口，临时文档和最近路径不成为长期配置身份。
    func keyboardCommandCatalog(_ root: NSMenu) throws -> [KeyboardCommandEntry] {
        var entries: [KeyboardCommandEntry] = []
        var positions: [String: Int] = [:]
        var pending = root.items.reversed().map {
            ($0, "")
        }
        while let (item, parent) = pending.popLast() {
            if let submenu = item.submenu {
                // 服务命令及其快捷键由系统和当前响应者管理，不能进入可迁移的 Nate 命令目录。
                if item.identifier?.rawValue == "nate.systemServices" {
                    continue
                }
                let category = parent.isEmpty ? item.title : parent + " / " + item.title
                pending.append(
                    contentsOf: submenu.items.reversed().map {
                        ($0, category)
                    }
                )
                continue
            }
            guard !item.isSeparatorItem, let action = item.action else {
                continue
            }
            let routed = item.representedObject as? String
            if routed?.hasPrefix("recent:") == true || routed?.hasPrefix("activate:") == true {
                continue
            }
            var id = routed ?? "native:" + NSStringFromSelector(action)
            for prefix in ["encoding:", "reinterpret:"] where id.hasPrefix(prefix) {
                guard let index = Int(id.dropFirst(prefix.count)),
                    TextEncoding.available.indices.contains(index)
                else {
                    throw NateError.message("编码命令没有稳定身份，快捷键未安装。")
                }
                let encoding = TextEncoding.available[index]
                id = prefix + "cp\(encoding.codePage):" + (encoding.bom ? "bom" : "plain")
            }
            let shortcut = NativeKeyboardShortcut.menu(
                key: item.keyEquivalent,
                modifiers: item.keyEquivalentModifierMask
            )
            if let index = positions[id] {
                entries[index].items.append(item)
                if let shortcut, !entries[index].defaults.contains(shortcut) {
                    entries[index].defaults.append(shortcut)
                }
            }
            else {
                positions[id] = entries.count
                entries.append(
                    KeyboardCommandEntry(
                        id: id,
                        title: item.title,
                        category: parent,
                        defaults: shortcut.map {
                            [$0]
                        } ?? [],
                        items: [item],
                        managedElsewhere: false
                    )
                )
            }
        }
        var occupied = Set(entries.flatMap(\.defaults))
        for key in ["h", "f", "s", "n", "o", "w", "g", "b", "i", "\t", "\u{F706}"] {
            for modifiers in UInt8(0)...15 {
                guard let command = CompatibilityShortcut.command(key: key, modifiers: modifiers),
                    let index = positions[command]
                else {
                    continue
                }
                let shortcut = try KeyboardShortcut(key: key, modifiers: modifiers)
                // 原生菜单先取得默认执行身份，兼容入口不能覆盖已有 Command 组合。
                if occupied.insert(shortcut).inserted {
                    entries[index].defaults.append(shortcut)
                }
            }
        }
        for definition in macroLibrary.definitions {
            entries.append(
                KeyboardCommandEntry(
                    id: "savedMacro:" + definition.id.uuidString,
                    title: definition.name,
                    category: "宏 / 命名宏",
                    defaults: definition.shortcut.map {
                        [$0]
                    } ?? [],
                    items: [],
                    managedElsewhere: true
                )
            )
        }
        for command in runCommands.library.commands {
            entries.append(
                KeyboardCommandEntry(
                    id: "savedRun:" + command.id.uuidString,
                    title: command.name,
                    category: "运行 / 命名配置",
                    defaults: command.shortcut.map {
                        [$0]
                    } ?? [],
                    items: [],
                    managedElsewhere: true
                )
            )
        }
        _ = try entries.map {
            try CommandKeyBinding(command: $0.id, shortcuts: $0.defaults)
        }
        return entries
    }

    /// 业务作用：完整解析后才替换菜单与兼容路由，冲突和未知覆盖不取得执行资格。
    /// 参数说明:
    /// - root: 当前正在构建的完整默认菜单。
    /// 返回：安装唯一实际组合；目录异常保留默认菜单并关闭配置写入。
    func installKeyboardMap(in root: NSMenu) {
        let runtime = keyboardMap
        do {
            let catalog = try keyboardCommandCatalog(root)
            let defaults = try catalog.map {
                try CommandKeyBinding(command: $0.id, shortcuts: $0.defaults)
            }
            let managed = Set(catalog.filter(\.managedElsewhere).map(\.id))
            let resolution = try KeyboardMapResolution(
                defaults: defaults,
                configuration: runtime.configuration,
                managedElsewhere: managed
            )
            runtime.catalog = catalog
            runtime.resolution = resolution
            guard runtime.ready else {
                return
            }
            for entry in catalog where !entry.managedElsewhere {
                let keys = resolution.active[entry.id] ?? []
                for item in entry.items {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
                guard let original = entry.items.first, let menu = original.menu else {
                    continue
                }
                for (index, key) in keys.enumerated() {
                    let item: NSMenuItem
                    if index == 0 {
                        item = original
                    }
                    else {
                        item = NSMenuItem(title: original.title, action: original.action, keyEquivalent: "")
                        item.target = original.target
                        item.representedObject = original.representedObject
                        item.isHidden = true
                        item.allowsKeyEquivalentWhenHidden = true
                        menu.addItem(item)
                    }
                    item.keyEquivalent = NativeKeyboardShortcut.menuKey(key)
                    item.keyEquivalentModifierMask = NativeKeyboardShortcut.modifiers(key)
                }
            }
            connectKeyboardMap()
        }
        catch {
            runtime.failure = error.localizedDescription
            runtime.writable = false
            runtime.resolution = nil
            mainWindow?.setDefaultKeyboardRoutes(active: true)
        }
        refreshKeyboardMapPresentation()
    }
}
