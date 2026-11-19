import AppKit
import NateCore
import NatePlatform
import NateUI

extension ApplicationController {
    /// 业务作用：快捷键管理只展示完整目录和配置，打开窗口不改变当前文档或执行命令。
    /// 参数说明: 无。
    /// 返回：当前配置面板成为前台，输入法确认失败时保留原焦点。
    func showKeyboardMap() {
        guard !closing, mainWindow?.finishCompositions() != false else {
            return
        }
        configureKeyboardMap()
        let runtime = keyboardMap
        if runtime.panel == nil {
            let panel = KeyboardMapPanel()
            panel.onChange = {
                [weak self] in self?.changeKeyboardBinding($0, shortcuts: $1)
            }
            panel.onImport = {
                [weak self] in self?.chooseKeyboardMapImport()
            }
            panel.onExport = {
                [weak self] in self?.exportKeyboardMap()
            }
            panel.onRestoreAll = {
                [weak self] in self?.restoreKeyboardMapDefaults()
            }
            panel.onRebuild = {
                [weak self] in self?.rebuildKeyboardMap()
            }
            panel.onManageExternal = {
                [weak self] command in
                guard let self else {
                    return
                }
                if command.hasPrefix("savedMacro:"), let id = UUID(uuidString: String(command.dropFirst(11)))
                {
                    self.showMacroLibrary()
                    self.macroLibrary.panel?.selectMacro(id)
                }
                if command.hasPrefix("savedRun:"), let id = UUID(uuidString: String(command.dropFirst(9))) {
                    self.showRunCommands()
                    self.runCommands.panel?.selectCommand(id)
                }
            }
            panel.onApplyImport = {
                [weak self] in
                guard let self, let candidate = self.keyboardMap.preview else {
                    return
                }
                self.saveKeyboardMap(candidate)
            }
            panel.onCancelImport = {
                [weak self] in self?.cancelKeyboardMapPreview()
            }
            panel.onClose = {
                [weak self] in self?.cancelKeyboardMapPreview()
            }
            runtime.panel = panel
        }
        refreshKeyboardMapPresentation()
        runtime.panel?.showWindow(nil)
        runtime.panel?.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：单项更新先复验当前命令与完整冲突，导入预览中的编辑只改变候选而不发布。
    /// 参数说明:
    /// - command: 实际命令或待移除的不可用覆盖身份。
    /// - shortcuts: 完整新组合，空数组禁用，空值恢复默认。
    /// 返回：无新增冲突时保存或更新预览；拒绝时保留原完整映射和原因。
    func changeKeyboardBinding(_ command: String, shortcuts: [KeyboardShortcut]?) {
        let runtime = keyboardMap
        guard canChangeKeyboardMap() else {
            return
        }
        let entry = runtime.catalog.first {
            $0.id == command
        }
        // 未提供和独立库管理的身份只能移除全局覆盖，不能借外来配置取得新执行入口。
        guard shortcuts == nil || entry?.managedElsewhere == false else {
            runtime.failure = "此身份不能在全局映射中添加绑定。"
            refreshKeyboardMapPresentation()
            return
        }
        do {
            let original = runtime.preview ?? runtime.configuration
            let candidate = try original.updating(command, shortcuts: shortcuts)
            let before = try resolveKeyboardMap(original)
            let after = try resolveKeyboardMap(candidate)
            let overridden = Set(candidate.overrides.map(\.command))
            if let conflict = after.conflicts.first(where: {
                overridden.contains($0.command) && !before.conflicts.contains($0)
            }) {
                let name =
                    runtime.catalog.first(where: {
                        $0.id == conflict.owner
                    })?.title ?? conflict.owner
                throw NateError.message(
                    NativeKeyboardShortcut.label(conflict.shortcut) + " 与“" + name + "”冲突，未改变绑定。"
                )
            }
            if runtime.preview != nil {
                runtime.preview = candidate
                runtime.failure = nil
                refreshKeyboardMapPresentation()
            }
            else {
                saveKeyboardMap(candidate)
            }
        }
        catch {
            runtime.failure = error.localizedDescription
            refreshKeyboardMapPresentation()
        }
    }

    /// 业务作用：目录解析始终来自当前实际菜单，归档中不存在的身份不参与按键执行。
    /// 参数说明:
    /// - configuration: 待查看或明确应用的完整配置。
    /// 返回：实际唯一所有者、冲突与不可用覆盖。
    func resolveKeyboardMap(_ configuration: KeyboardMap) throws -> KeyboardMapResolution {
        try KeyboardMapResolution(
            defaults: keyboardMap.catalog.map {
                try CommandKeyBinding(command: $0.id, shortcuts: $0.defaults)
            },
            configuration: configuration,
            managedElsewhere: Set(keyboardMap.catalog.filter(\.managedElsewhere).map(\.id))
        )
    }

    /// 业务作用：预览详情区分期望和正在执行的绑定，冲突与系统保留组合均提供完整原因。
    /// 参数说明: 无。
    /// 返回：仅刷新已有面板，不抢回焦点或主动显示窗口。
    func refreshKeyboardMapPresentation() {
        let runtime = keyboardMap
        guard let panel = runtime.panel else {
            return
        }
        let candidate = runtime.preview ?? runtime.configuration
        let requested = Dictionary(
            uniqueKeysWithValues: candidate.overrides.map {
                ($0.command, $0.shortcuts)
            }
        )
        let preview = try? resolveKeyboardMap(candidate)
        var rows: [KeyboardCommandPresentation] = []
        for entry in runtime.catalog {
            var notes = (preview?.conflicts ?? []).filter {
                $0.command == entry.id
            }.map {
                conflict in
                let owner =
                    runtime.catalog.first(where: {
                        $0.id == conflict.owner
                    })?.title ?? conflict.owner
                return NativeKeyboardShortcut.label(conflict.shortcut) + " 与“" + owner + "”冲突，保持停用。"
            }
            if entry.managedElsewhere, requested[entry.id] != nil {
                notes.append("全局覆盖对此身份不生效；可恢复所选默认以移除该项覆盖。")
            }
            if (requested[entry.id] ?? entry.defaults).contains(where: {
                $0.modifiers & 4 != 0
            }) {
                notes.append("此 Control 组合按应用映射执行，会覆盖文本控件的同名 Control 动作；输入法候选和明确捕获仍优先。")
            }
            if (requested[entry.id] ?? entry.defaults).contains(where: {
                $0.modifiers & 4 != 0 && ($0.key == " " || ["\u{F700}", "\u{F701}"].contains($0.key))
            }) {
                notes.append("此 Control 组合可能由输入源或 Mission Control 使用；系统设置优先，仅处理应用实际收到的事件。")
            }
            rows.append(
                KeyboardCommandPresentation(
                    id: entry.id,
                    title: entry.title,
                    category: entry.category,
                    defaults: entry.defaults,
                    active: runtime.resolution?.active[entry.id] ?? [],
                    requested: requested[entry.id],
                    notes: notes,
                    available: true,
                    managedElsewhere: entry.managedElsewhere
                )
            )
        }
        let known = Set(runtime.catalog.map(\.id))
        for override in candidate.overrides where !known.contains(override.command) {
            rows.append(
                KeyboardCommandPresentation(
                    id: override.command,
                    title: override.command,
                    category: "不可用命令",
                    defaults: [],
                    active: [],
                    requested: override.shortcuts,
                    notes: [],
                    available: false,
                    managedElsewhere: false
                )
            )
        }
        var message = runtime.failure
        if let name = runtime.previewName {
            message =
                "导入预览：" + name + "。尚未应用，冲突与不可用记录完整保留。"
                + (message.map {
                    "\n" + $0
                } ?? "")
        }
        panel.update(
            commands: rows,
            writable: runtime.writable,
            busy: runtime.task != nil || runtime.importTask != nil,
            message: message,
            previewing: runtime.preview != nil
        )
    }

    /// 业务作用：全部默认作为一份完整配置明确确认，不逐项产生半完成状态。
    /// 参数说明: 无。
    /// 返回：确认后移除全局覆盖，独立命名宏绑定保持原定义。
    func restoreKeyboardMapDefaults() {
        guard canChangeKeyboardMap(), keyboardMap.preview == nil else {
            return
        }
        let question = NSAlert()
        question.messageText = "恢复全部默认快捷键？"
        question.informativeText = "将移除全部全局用户覆盖。命名宏的绑定仍由宏管理保存。"
        question.addButton(withTitle: "恢复默认")
        question.addButton(withTitle: "取消")
        if question.runModal() == .alertFirstButtonReturn {
            saveKeyboardMap(KeyboardMap())
        }
    }
}
