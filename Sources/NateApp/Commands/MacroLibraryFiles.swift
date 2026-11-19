import AppKit
import NateCore
import NatePlatform
import NateUI

extension ApplicationController {
    /// 业务作用：临时宏文件完整读取后先展示实际动作，等待期间发生的新录制或导航不能被旧载入替换。
    /// 参数说明:
    /// - url: 用户明确选择的宏文件。
    /// 返回：当前来源仍一致时安装临时动作并显示预览；失效时保留当前录制和已读取预览供明确查看。
    func importTemporaryMacro(_ url: URL) async {
        guard !closing, !macroRecording, !macroPlaying, macroPlayback.task == nil,
            let window = mainWindow, let document = active, window.finishCompositions()
        else {
            return
        }
        let runtime = macroLibrary
        let request = UUID()
        runtime.importGeneration = request
        let recording = macroRecordingGeneration, actions = macroActionsGeneration
        let playback = macroPlayback.generation
        let editor = window.editor
        let focus = editor.focusGeneration, selection = editor.selectionGeneration
        let revision = document.buffer.revision
        do {
            let definition = try await readIO.readCancellable {
                token in
                let data = try self.fileAccess.readData(
                    url,
                    maximumBytes: MacroArchive.maximumBytes,
                    permit: {
                        !token.isCancelled
                    }
                ).data
                return try NamedMacro(
                    id: UUID(),
                    name: "载入的临时宏",
                    archive: data,
                    shortcut: nil,
                    permit: {
                        !token.isCancelled
                    }
                )
            }
            guard !closing, runtime.importGeneration == request else {
                return
            }
            runtime.previewDefinition = definition
            runtime.preview?.window?.representedURL = url
            // 配置读取不拥有后来录制、选择或焦点的替换权，往返后的相同内容也不能恢复旧资格。
            guard !macroRecording, !macroPlaying, macroPlayback.task == nil,
                macroRecordingGeneration == recording, macroActionsGeneration == actions,
                macroPlayback.generation == playback, mainWindow === window, active === document,
                window.editor === editor, editor.focusGeneration == focus,
                editor.selectionGeneration == selection, document.buffer.revision == revision
            else {
                window.status.stringValue = "宏文件已读取，但当前输入或焦点已改变；未替换录制，可从宏菜单查看文件预览。"
                refreshMacroLibraryPresentation()
                return
            }
            macroActions = definition.actions
            showTemporaryMacroPreview()
            runtime.preview?.window?.representedURL = url
        }
        catch is CancellationError {
            return
        }
        catch {
            guard !closing, runtime.importGeneration == request else {
                return
            }
            SystemIntegration.alert("宏载入失败", error.localizedDescription)
        }
    }

    /// 业务作用：文件预览展示完整动作，播放与保存为命名宏分别由用户明确选择。
    /// 参数说明: 无。
    /// 返回：不因打开或选择预览而执行动作，不改写当前临时录制。
    func showTemporaryMacroPreview() {
        let runtime = macroLibrary
        guard !closing, runtime.previewDefinition != nil, mainWindow?.finishCompositions() != false else {
            return
        }
        if runtime.preview == nil {
            let panel = MacroLibraryPanel(previewOnly: true)
            panel.onSaveCurrent = {
                [weak self] in self?.savePreviewToLibrary()
            }
            panel.onExport = {
                [weak self] id in
                guard let self, let definition = self.macroLibrary.previewDefinition, definition.id == id
                else {
                    return
                }
                self.exportMacroDefinition(definition)
            }
            panel.onPlay = {
                [weak self] id, count, untilEnd in
                guard let self, let definition = self.macroLibrary.previewDefinition, definition.id == id
                else {
                    return
                }
                self.playMacroDefinition(
                    definition,
                    repetitions: count,
                    activatingEditor: true,
                    untilDocumentEnd: untilEnd
                )
            }
            panel.onStop = {
                [weak self] in self?.cancelMacro()
            }
            runtime.preview = panel
        }
        refreshMacroLibraryPresentation()
        runtime.preview?.showWindow(nil)
        runtime.preview?.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：导入预览保存为新的命名身份，原文件与当前临时录制均保持原状。
    /// 参数说明: 无。
    /// 返回：名称确认后完整保存，重复保存不会复用预览身份覆盖已有记录。
    func savePreviewToLibrary() {
        guard canChangeMacroLibrary(), let definition = macroLibrary.previewDefinition,
            let name = SystemIntegration.prompt("保存为命名宏", "输入宏名称", initial: suggestedMacroName())
        else {
            return
        }
        let archive = definition.archive
        changeMacroLibrary {
            definitions in
            definitions + [try NamedMacro(id: UUID(), name: name, archive: archive, shortcut: nil)]
        }
    }
}
