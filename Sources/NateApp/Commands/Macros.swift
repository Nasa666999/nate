import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：只记录已提交的语义输入，预编辑和磁盘保存不进入宏。
    /// 参数说明:
    /// - value: 用户实际确认的文字，不含虚拟列补齐空白。
    /// 返回：追加可在新光标位置重放的输入动作。
    func recordTextInput(_ value: String) {
        guard macroRecording, !macroPlaying, quickFindContext() != nil else {
            return
        }
        macroActions.append(.input(value))
    }

    /// 业务作用：粘贴宏记录实际载荷与明确换行选项，目标 Tab 保留或定位空白不会变成输入内容。
    /// 参数说明:
    /// - payload: 本次实际成功粘贴的完整内容与形态。
    /// - adapting: 本次明确采用的插入换行适配。
    /// 返回：仅同一录制控制代次内的成功动作追加一次。
    func recordClipboardPaste(_ payload: ClipboardPayload, adapting: Bool) {
        guard macroRecording, !macroPlaying, clipboardRecordingGeneration == macroRecordingGeneration,
            quickFindContext() != nil
        else {
            return
        }
        macroActions.append(.clipboard(payload, adaptLineEndings: adapting))
    }

    /// 业务作用：按有界次数播放语义动作，循环间让出主事件循环。
    /// 参数说明:
    /// - repetitions: 用户指定次数。
    /// 返回：输入、转换、排序或粘贴失败立即停止，取消、切换或只读时停止；正文和选择均无进展时结束重复。
    func playMacro(repetitions: Int) async {
        guard (1...10_000).contains(repetitions), macroActions.count <= 10_000,
            !macroRecording, !macroPlaying, !macroActions.isEmpty,
            let active
        else {
            return
        }
        let actions = macroActions
        let generation = macroPlayback.generation
        do {
            for action in actions {
                try action.validateSupport()
            }
        }
        catch {
            mainWindow?.status.stringValue = "宏已停止：" + error.localizedDescription
            return
        }
        // 未知动作已经整份拒绝后才允许确认原候选，非法宏不能以输入法确认的副作用改变正文。
        guard mainWindow?.editor.finishComposition() != false, self.active === active,
            macroPlayback.generation == generation,
            let (document, window, editor) = quickFindContext(), document === active
        else {
            return
        }
        var proof = MacroPlaybackProof(document: document, window: window, editor: editor)
        macroPlaying = true
        defer {
            macroPlaying = false
        }
        for _ in 0..<repetitions {
            guard macroPlayback.generation == generation, proof.matches(self)
            else {
                break
            }
            let revision = active.buffer.revision
            let selectionGeneration = active.buffer.selectionGeneration
            for action in actions {
                // 每个后台动作返回后重新取得原实例与实际焦点，宏不能沿后续同名标签继续编辑。
                guard macroPlayback.generation == generation, proof.matches(self)
                else {
                    return
                }
                switch action {
                case .input(let text):
                    guard insert(text) else {
                        return
                    }
                case .command(let name):
                    if let command = TextCommand(rawValue: name) {
                        if let options = command.lineSortOptions {
                            guard await playLineSort(options) else {
                                return
                            }
                        }
                        else {
                            guard edit(command) else {
                                return
                            }
                        }
                    }
                    else {
                        mainWindow?.status.stringValue = "宏已停止：无法识别的编辑动作“" + name + "”。"
                        return
                    }
                case .lineSort(let options):
                    guard await playLineSort(options) else {
                        return
                    }
                case .clipboard(let payload, let adapt):
                    guard let editor = quickFindContext()?.2,
                        await editor.pastePayload(payload, adaptLineEndings: adapt)
                    else {
                        return
                    }
                }
                // 成功结果先成为下一项的明确来源，再让用户事件进入；让出后发生的外来编辑不能被收编。
                guard macroPlayback.generation == generation, proof.matchesAuthority(self) else {
                    return
                }
                proof.advance()
                await Task.yield()
            }
            if active.buffer.revision == revision && active.buffer.selectionGeneration == selectionGeneration
            {
                break
            }
        }
    }

    /// 业务作用：宏等待同一排序身份的实际成功，失败或取消不能先执行下一项语义输入。
    /// 参数说明:
    /// - options: 宏明确记录的完整排序参数。
    /// 返回：原动作真实完成时为真，无法启动、取消、过期或失败时为假。
    private func playLineSort(_ options: LineSortOptions) async -> Bool {
        guard let request = performLineSort(options), let pending = lineSorting.task else {
            return false
        }
        await withTaskCancellationHandler(
            operation: {
                await pending.value
            },
            onCancel: {
                pending.cancel()
            }
        )
        return !Task.isCancelled && lineSorting.succeeded == request
    }

    /// 业务作用：将宏作为独立配置安全保存，载入不会自动执行动作。
    /// 参数说明: 无。
    /// 返回：持久化当前语义动作列表。
    func saveMacro() {
        guard !macroPlaying, macroPlayback.task == nil, !macroRecording,
            !macroActions.isEmpty, let url = SystemIntegration.chooseSave(name: "Macro.natemacro")
        else {
            return
        }
        let actions = macroActions
        Task {
            do {
                try await fileIO.run {
                    let data = try MacroArchive.encode(actions)
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
                SystemIntegration.alert("宏保存失败", error.localizedDescription)
            }
        }
    }

    /// 业务作用：载入经过规模和动作校验的宏，执行仍需用户主动选择。
    /// 参数说明: 无。
    /// 返回：保留旧宏直到新配置完整解码成功。
    func loadMacro() {
        guard !macroPlaying, macroPlayback.task == nil, !macroRecording,
            let url = SystemIntegration.chooseFiles().first
        else {
            return
        }
        Task {
            do {
                let actions = try await readIO.readCancellable {
                    token in
                    let data = try self.fileAccess.readData(
                        url,
                        maximumBytes: MacroArchive.maximumBytes,
                        permit: {
                            !token.isCancelled
                        }
                    ).data
                    return try MacroArchive.decode(
                        data,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                macroActions = actions
                SystemIntegration.alert("宏已载入", "\(actions.count) 个动作。选择“播放一次”或“重复执行”后才会修改文档。")
            }
            catch {
                SystemIntegration.alert("宏载入失败", error.localizedDescription)
            }
        }
    }
}
