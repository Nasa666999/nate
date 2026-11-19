import AppKit
import NateCore
import NatePlatform
import NateUI

extension ApplicationController {
    /// 业务作用：原生管理面板仅查看命名定义，打开面板先完成正文候选，不隐式播放任何宏。
    /// 参数说明: 无。
    /// 返回：展示当前宏库与实际保存状态，目录尚未就绪或候选失败时保留原焦点。
    func showMacroLibrary() {
        guard !closing, applicationSupport != nil, mainWindow?.finishCompositions() != false else {
            return
        }
        configureMacroLibrary()
        if macroLibrary.panel == nil {
            let panel = MacroLibraryPanel()
            panel.onSaveCurrent = {
                [weak self] in self?.saveRecordingToLibrary()
            }
            panel.onImport = {
                [weak self] in self?.importMacroToLibrary()
            }
            panel.onExport = {
                [weak self] id in
                guard let self,
                    let definition = self.macroLibrary.definitions.first(where: {
                        $0.id == id
                    })
                else {
                    return
                }
                self.exportMacroDefinition(definition)
            }
            panel.onRename = {
                [weak self] in self?.renameNamedMacro($0, name: $1)
            }
            panel.onDelete = {
                [weak self] in self?.deleteNamedMacro($0)
            }
            panel.onShortcut = {
                [weak self] in self?.assignNamedMacroShortcut($0, shortcut: $1)
            }
            panel.onPlay = {
                [weak self] in
                self?.playNamedMacro($0, repetitions: $1, activatingEditor: true, untilDocumentEnd: $2)
            }
            panel.onStop = {
                [weak self] in self?.cancelMacro()
            }
            panel.onReset = {
                [weak self] in self?.resetMacroLibrary()
            }
            macroLibrary.panel = panel
        }
        refreshMacroLibraryPresentation()
        macroLibrary.panel?.showWindow(nil)
        macroLibrary.panel?.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：当前录制停止后才固定动作与用户名称，不把继续录制的内容混进一次保存。
    /// 参数说明: 无。
    /// 返回：明确确认名称后保存一份独立宏，取消不改变临时录制。
    func saveRecordingToLibrary() {
        guard canChangeMacroLibrary(), !macroActions.isEmpty,
            let name = SystemIntegration.prompt("保存当前录制为命名宏", "输入宏名称", initial: suggestedMacroName())
        else {
            return
        }
        addNamedMacro(name: name, actions: macroActions)
    }

    /// 业务作用：完整录制作为独立稳定身份进入库，原临时动作仍可继续保存或重放。
    /// 参数说明:
    /// - name: 用户明确给出的名称。
    /// - actions: 点击保存时固定的完整录制快照。
    /// 返回：后台准备和完整保存，不覆盖同名宏或改变正文。
    func addNamedMacro(name: String, actions: [MacroAction]) {
        changeMacroLibrary {
            definitions in definitions + [try NamedMacro(name: name, actions: actions)]
        }
    }

    /// 业务作用：导入宏只加入命名库，兼容归档保持原字节且不会替换临时录制或执行正文动作。
    /// 参数说明: 无。
    /// 返回：用户选择文件与名称后完整验证并保存，失败保留原库。
    func importMacroToLibrary() {
        guard canChangeMacroLibrary(), let url = SystemIntegration.chooseFiles().first,
            let name = SystemIntegration.prompt("导入为命名宏", "输入宏名称；导入不会执行动作。", initial: suggestedMacroName())
        else {
            return
        }
        let access = fileAccess
        changeMacroLibrary {
            definitions in
            let data = try access.readData(url, maximumBytes: MacroArchive.maximumBytes).data
            return definitions + [try NamedMacro(id: UUID(), name: name, archive: data, shortcut: nil)]
        }
    }

    /// 业务作用：导出明确选中的完整宏，重命名和快捷键不改变导出动作内容。
    /// 参数说明:
    /// - definition: 用户明确选择的不可变定义。
    /// 返回：目标基线复验后安全保存；取消或冲突保留原文件，不执行动作。
    func exportMacroDefinition(_ definition: NamedMacro) {
        let filename = definition.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: ":",
            with: "_"
        )
        guard !closing, let url = SystemIntegration.chooseSave(name: filename + ".natemacro") else {
            return
        }
        let data = definition.archive
        Task {
            do {
                try await fileIO.run {
                    let expected =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try self.fileAccess.baseline(url) : nil
                    _ = try self.fileOperations.save(
                        using: self.fileAccess,
                        data,
                        to: url,
                        expected: expected,
                        replacing: true
                    )
                }
            }
            catch {
                SystemIntegration.alert("宏导出失败", error.localizedDescription)
            }
        }
    }

    /// 业务作用：名称修改绑定稳定身份，不按列表行号更新另一个宏。
    /// 参数说明:
    /// - id: 用户当前选中的宏身份。
    /// - name: 待保存的新名称。
    /// 返回：完整验证唯一名称后保存，失败保留原定义与输入草稿。
    func renameNamedMacro(_ id: UUID, name: String) {
        changeMacroLibrary {
            definitions in
            guard
                let index = definitions.firstIndex(where: {
                    $0.id == id
                })
            else {
                throw NateError.message("所选宏已经不存在。")
            }
            var result = definitions
            result[index] = try definitions[index].updating(name: name, shortcut: definitions[index].shortcut)
            return result
        }
    }

    /// 业务作用：明确删除只移除命名定义，临时录制、正文和已完成的播放步骤保持原状。
    /// 参数说明:
    /// - id: 用户明确选择的稳定身份。
    /// 返回：新列表可靠保存后，删除身份也从上一份回退列表排除。
    func deleteNamedMacro(_ id: UUID) {
        changeMacroLibrary {
            definitions in
            guard
                definitions.contains(where: {
                    $0.id == id
                })
            else {
                throw NateError.message("所选宏已经不存在。")
            }
            return definitions.filter {
                $0.id != id
            }
        }
    }

    /// 业务作用：快捷键先检查现有命令冲突，再随完整库一起保存，不靠菜单排列选中一个动作。
    /// 参数说明:
    /// - id: 需要更新绑定的稳定宏身份。
    /// - shortcut: 待应用组合，空值明确解除绑定。
    /// 返回：无冲突时完整保存；冲突保留既有命令与用户待应用组合。
    func assignNamedMacroShortcut(_ id: UUID, shortcut: MacroShortcut?) {
        guard canChangeMacroLibrary() else {
            return
        }
        if let shortcut, let conflict = macroShortcutConflict(shortcut, excluding: id) {
            macroLibrary.failure = "快捷键与“" + conflict + "”冲突，未改变绑定。"
            refreshMacroLibraryPresentation()
            return
        }
        changeMacroLibrary {
            definitions in
            guard
                let index = definitions.firstIndex(where: {
                    $0.id == id
                })
            else {
                throw NateError.message("所选宏已经不存在。")
            }
            var result = definitions
            result[index] = try definitions[index].updating(name: definitions[index].name, shortcut: shortcut)
            return result
        }
    }

    /// 业务作用：命名宏播放使用选中定义的不可变动作，不替换用户的临时录制。
    /// 参数说明:
    /// - id: 当前仍存在的命名宏身份。
    /// - repetitions: 明确的播放次数。
    /// - activatingEditor: 管理面板按钮是否明确请求回到正文；键盘入口仍要求已有正文焦点。
    /// - untilDocumentEnd: 按完整轮次检查文末，而非按次数结束。
    /// 返回：目标与候选均允许时启动独立播放，否则保留当前界面和内容。
    func playNamedMacro(
        _ id: UUID,
        repetitions: Int = 1,
        activatingEditor: Bool = false,
        untilDocumentEnd: Bool = false
    ) {
        guard !closing, !macroRecording, !macroPlaying, macroPlayback.task == nil,
            macroLibrary.ready, macroLibrary.task == nil,
            let definition = macroLibrary.definitions.first(where: {
                $0.id == id
            })
        else {
            return
        }
        playMacroDefinition(
            definition,
            repetitions: repetitions,
            activatingEditor: activatingEditor,
            untilDocumentEnd: untilDocumentEnd
        )
    }

    /// 业务作用：用户明确播放已查看的动作后复验正文目标，预览文件与已保存宏使用同一播放入口。
    /// 参数说明:
    /// - definition: 已完整校验且用户明确选择的动作快照。
    /// - repetitions: 一至一万次。
    /// - activatingEditor: 是否由面板明确切回实际编辑器。
    /// - untilDocumentEnd: 按完整轮次检查主光标是否到达文末。
    /// 返回：不改变临时录制的独立播放；候选或焦点失败不执行。
    func playMacroDefinition(
        _ definition: NamedMacro,
        repetitions: Int,
        activatingEditor: Bool,
        untilDocumentEnd: Bool = false
    ) {
        guard !closing, !macroRecording, !macroPlaying, macroPlayback.task == nil,
            mainWindow?.finishCompositions() != false
        else {
            return
        }
        if activatingEditor {
            mainWindow?.window?.makeKeyAndOrderFront(nil)
            guard mainWindow?.window?.makeFirstResponder(mainWindow?.editor) == true else {
                return
            }
        }
        guard quickFindContext() != nil else {
            return
        }
        startMacro(repetitions: repetitions, actions: definition.actions, untilDocumentEnd: untilDocumentEnd)
    }

    /// 业务作用：新建名称避开现存定义，不用覆盖同名记录来保存另一次录制。
    /// 参数说明: 无。
    /// 返回：当前库中尚未使用的可辨认名称。
    func suggestedMacroName() -> String {
        let names = Set(macroLibrary.definitions.map(\.name))
        var name = "新宏", index = 2
        while names.contains(name) {
            name = "新宏 \(index)"
            index += 1
        }
        return name
    }

    /// 业务作用：保存与播放只更新已有可见面板，不在后台处理完成时抢回编辑焦点。
    /// 参数说明: 无。
    /// 返回：管理与文件预览的按钮、实际内容及错误状态与当前任务一致。
    func refreshMacroLibraryPresentation() {
        let runtime = macroLibrary
        let playing = macroPlaying || macroPlayback.task != nil
        if let panel = runtime.panel {
            let warning = [runtime.failure, macroShortcutWarning(), macroRecorder.notice].compactMap {
                $0
            }.joined(separator: "\n")
            panel.update(
                definitions: runtime.definitions,
                writable: runtime.writable && !macroRecording,
                busy: runtime.task != nil || !runtime.ready,
                canSaveCurrent: !macroRecording && !macroActions.isEmpty,
                playing: playing,
                failure: warning.isEmpty ? nil : warning
            )
        }
        if let panel = runtime.preview, let definition = runtime.previewDefinition {
            panel.update(
                definitions: [definition],
                writable: canChangeMacroLibrary(),
                busy: false,
                canSaveCurrent: true,
                playing: playing,
                failure: nil
            )
        }
    }
}
