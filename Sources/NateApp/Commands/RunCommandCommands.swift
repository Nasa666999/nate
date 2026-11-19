import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：命名配置通过同一原生面板查看和管理，一次运行只建立新的未保存输入。
    /// 参数说明:
    /// - newDraft: 是否明确进入新的临时配置输入。
    /// 返回：完成原候选后显示窗口，查看或新建均不启动进程。
    func showRunCommands(newDraft: Bool = false) {
        guard !closing, mainWindow?.finishCompositions() != false else {
            return
        }
        configureRunCommands()
        let runtime = runCommands
        runtime.newDraftRequested = runtime.newDraftRequested || newDraft
        if runtime.panel == nil {
            let panel = RunCommandPanel()
            panel.onSave = {
                [weak self] in self?.saveRunCommandDraft($0)
            }
            panel.onPrepare = {
                [weak self] in self?.prepareRunCommandDraft($0)
            }
            panel.onDelete = {
                [weak self] in self?.deleteRunCommand($0)
            }
            panel.onImport = {
                [weak self] in self?.chooseRunCommandImport()
            }
            panel.onExport = {
                [weak self] in self?.exportRunCommands()
            }
            panel.onApplyImport = {
                [weak self] in
                guard let self, let candidate = self.runCommands.importCandidate else {
                    return
                }
                self.saveRunCommands(candidate)
            }
            panel.onCancelImport = {
                [weak self] in self?.cancelRunCommandImport()
            }
            panel.onRebuild = {
                [weak self] in self?.rebuildRunCommands()
            }
            panel.onInvalidate = {
                [weak self] in self?.cancelRunCommandPreparation()
            }
            panel.onClose = {
                [weak self] in
                self?.cancelRunCommandImport()
                self?.cancelRunCommandPreparation()
            }
            runtime.panel = panel
        }
        refreshRunCommandPresentation()
        runtime.panel?.showWindow(nil)
        runtime.panel?.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：配置、导入与实际准备状态分别展示，后台完成不主动显示窗口或替换同身份草稿。
    /// 参数说明: 无。
    /// 返回：仅更新已有管理面板和明确待建立的新输入。
    func refreshRunCommandPresentation() {
        let runtime = runCommands
        guard let panel = runtime.panel else {
            return
        }
        let library = runtime.importCandidate ?? runtime.library
        var messages: [String] = []
        if let failure = runtime.failure {
            messages.append(failure)
        }
        if let failure = runtime.preparationFailure {
            messages.append(failure)
        }
        if let name = runtime.importName {
            messages.append("导入预览：" + name + "；尚未应用或执行。应用完整导入将替换当前已保存列表。")
        }
        messages.append(contentsOf: runCommandBindingWarnings(library))
        let busy = runtime.task != nil || runtime.importTask != nil || runtime.prepareTask != nil
        panel.update(
            commands: library.commands,
            writable: runtime.writable,
            busy: busy,
            running: externalCommandTask != nil,
            previewing: runtime.importCandidate != nil,
            message: messages.isEmpty ? nil : messages.joined(separator: "\n")
        )
        if runtime.newDraftRequested, runtime.ready, !busy, runtime.importCandidate == nil {
            runtime.newDraftRequested = false
            panel.beginNewCommand()
        }
    }

    /// 业务作用：导入中的绑定按完整候选重新解析，准备删除的旧命令不继续占用新列表的组合。
    /// 参数说明:
    /// - library: 当前真实列表或完整导入候选。
    /// 返回：完整冲突说明，不改变归档中的绑定或执行任何命令。
    func runCommandBindingWarnings(_ library: RunCommandLibrary) -> [String] {
        do {
            let catalog = keyboardMap.catalog.filter {
                !$0.id.hasPrefix("savedRun:")
            }
            var defaults = try catalog.map {
                try CommandKeyBinding(command: $0.id, shortcuts: $0.defaults)
            }
            var managed = Set(catalog.filter(\.managedElsewhere).map(\.id))
            for command in library.commands {
                let id = "savedRun:" + command.id.uuidString
                defaults.append(
                    try CommandKeyBinding(
                        command: id,
                        shortcuts: command.shortcut.map {
                            [$0]
                        } ?? []
                    )
                )
                managed.insert(id)
            }
            let resolution = try KeyboardMapResolution(
                defaults: defaults,
                configuration: keyboardMap.configuration,
                managedElsewhere: managed
            )
            return resolution.conflicts.filter {
                $0.command.hasPrefix("savedRun:")
            }.map {
                conflict in
                let name =
                    library.commands.first(where: {
                        "savedRun:" + $0.id.uuidString == conflict.command
                    })?.name ?? conflict.command
                let owner =
                    catalog.first(where: {
                        $0.id == conflict.owner
                    })?.title
                    ?? library.commands.first(where: {
                        "savedRun:" + $0.id.uuidString == conflict.owner
                    })?.name
                    ?? conflict.owner
                return name + "：" + NativeKeyboardShortcut.label(conflict.shortcut) + " 与“" + owner
                    + "”冲突，快捷键未启用。"
            }
        }
        catch {
            return ["绑定目录未安装：" + error.localizedDescription]
        }
    }
}
