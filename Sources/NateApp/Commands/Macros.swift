import AppKit
import NateCore
import NatePlatform
import NateStorage

enum MacroAction: Codable, Sendable {
    case input(String)
    case command(String)
}

extension ApplicationController {
    /// 业务作用：只记录已提交的语义输入，预编辑和磁盘保存不进入宏。
    /// 参数说明:
    /// - document: 刚完成事务的文档。
    /// 返回：追加可在新光标位置重放的输入动作。
    func recordTextChange(_ document: WorkspaceDocument) {
        guard ["输入", "粘贴"].contains(document.buffer.lastActionName),
            let first = document.buffer.lastEdits.first
        else {
            return
        }
        if document.buffer.lastEdits.allSatisfy({
            $0.text.utf8.elementsEqual(first.text.utf8)
        }) {
            macroActions.append(.input(first.text))
        }
    }

    /// 业务作用：按有界次数播放语义动作，循环间让出主事件循环。
    /// 参数说明:
    /// - repetitions: 用户指定次数。
    /// 返回：取消、文档切换或只读时停止，零进展不会无限运行。
    func playMacro(repetitions: Int) async {
        guard !macroRecording, !macroPlaying, let active else {
            return
        }
        let id = active.buffer.id
        let actions = macroActions
        macroPlaying = true
        defer {
            macroPlaying = false
        }
        for _ in 0..<repetitions {
            guard !Task.isCancelled, !closing, self.active?.buffer.id == id, !active.buffer.isReadOnly,
                !active.buffer.isEditingSuspended
            else {
                break
            }
            let revision = active.buffer.revision
            for action in actions {
                switch action {
                case .input(let text): insert(text)
                case .command(let name):
                    if let command = TextCommand(rawValue: name) {
                        edit(command)
                    }
                }
                await Task.yield()
            }
            if active.buffer.revision == revision {
                break
            }
        }
    }

    /// 业务作用：将宏作为独立配置安全保存，载入不会自动执行动作。
    /// 参数说明: 无。
    /// 返回：持久化当前语义动作列表。
    func saveMacro() {
        guard !macroActions.isEmpty, let url = SystemIntegration.chooseSave(name: "Macro.natemacro") else {
            return
        }
        let actions = macroActions
        Task {
            do {
                try await fileIO.run {
                    let data = try JSONEncoder().encode(actions)
                    let expected =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try self.fileAccess.baseline(url) : nil
                    _ = try self.fileAccess.save(data, to: url, expected: expected, replacing: true)
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
        guard let url = SystemIntegration.chooseFiles().first else {
            return
        }
        Task {
            do {
                let actions = try await readIO.readCancellable {
                    token in
                    let data = try self.fileAccess.readData(
                        url,
                        maximumBytes: 8_388_608,
                        permit: {
                            !token.isCancelled
                        }
                    ).data
                    let actions = try JSONDecoder().decode([MacroAction].self, from: data)
                    guard actions.count <= 10_000 else {
                        throw NateError.message("宏动作超过 10000 项。")
                    }
                    return actions
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
