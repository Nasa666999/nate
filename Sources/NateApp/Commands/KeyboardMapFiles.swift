import AppKit
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：用户明确选择的映射先完整读取，文件内容不在读取完成时自动替换现有绑定。
    /// 参数说明: 无。
    /// 返回：选择文件后开始只读导入；取消保留原配置。
    func chooseKeyboardMapImport() {
        guard canChangeKeyboardMap(), keyboardMap.preview == nil else {
            return
        }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.message = "选择快捷键映射，完整读取后先预览。"
        guard chooser.runModal() == .OK, let url = chooser.url else {
            return
        }
        importKeyboardMap(url)
    }

    /// 业务作用：完整受限解析先于预览发布，关闭窗口、配置往返或后来导入使旧读取立即失去替换资格。
    /// 参数说明:
    /// - url: 用户明确选择的普通映射文件。
    /// 返回：来源仍有效时保留完整候选供明确应用；取消、损坏或超量保持实际绑定原状。
    func importKeyboardMap(_ url: URL) {
        let runtime = keyboardMap
        guard canChangeKeyboardMap(), runtime.preview == nil else {
            return
        }
        let request = UUID(), generation = runtime.generation
        runtime.importGeneration = request
        runtime.importID = request
        let access = fileAccess
        let token = CancellationToken()
        runtime.importTask = Task {
            [weak self] in
            defer {
                if runtime.importID == request {
                    runtime.importTask = nil
                    runtime.importID = nil
                }
                self?.refreshKeyboardMapPresentation()
            }
            do {
                let candidate = try await withTaskCancellationHandler {
                    try await runtime.io.run {
                        try token.check()
                        let bytes = try access.readData(
                            url,
                            maximumBytes: KeyboardMapArchive.maximumBytes,
                            permit: {
                                !token.isCancelled
                            }
                        ).data
                        return try KeyboardMapArchive.decode(
                            bytes,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                } onCancel: {
                    token.cancel()
                }
                // 只读完成不拥有后来配置或窗口的替换权，也不恢复已经关闭的面板。
                guard let self, !self.closing, !Task.isCancelled,
                    runtime.importGeneration == request, runtime.generation == generation
                else {
                    return
                }
                _ = try self.resolveKeyboardMap(candidate)
                runtime.preview = candidate
                runtime.previewName = url.lastPathComponent
                runtime.failure = nil
            }
            catch is CancellationError {
                return
            }
            catch {
                guard !Task.isCancelled, runtime.importGeneration == request else {
                    return
                }
                runtime.failure = "导入未应用：" + error.localizedDescription
            }
        }
        refreshKeyboardMapPresentation()
    }

    /// 业务作用：关闭、取消和退出撤销只读导入资格，实际任务句柄仍保留到系统读取返回。
    /// 参数说明: 无。
    /// 返回：旧读取不能发布预览，未返回任务不能与下一次读取重叠。
    func cancelKeyboardMapImport() {
        keyboardMap.importGeneration = UUID()
        keyboardMap.importTask?.cancel()
    }

    /// 业务作用：撤去尚未应用的完整候选，不改变已保存配置或真实菜单。
    /// 参数说明: 无。
    /// 返回：恢复查看当前映射，正在读取的旧候选失权。
    func cancelKeyboardMapPreview() {
        cancelKeyboardMapImport()
        keyboardMap.preview = nil
        keyboardMap.previewName = nil
        refreshKeyboardMapPresentation()
    }

    /// 业务作用：导出保留当前完整用户覆盖，包括未应用预览中明确保留的不可用和冲突记录。
    /// 参数说明: 无。
    /// 返回：目标基线复验后保存完整归档；取消或失败不改变正在执行的绑定。
    func exportKeyboardMap() {
        let runtime = keyboardMap
        guard !closing, runtime.ready, runtime.task == nil, runtime.importTask == nil,
            let url = SystemIntegration.chooseSave(name: "Nate.natekeys")
        else {
            return
        }
        let candidate = runtime.preview ?? runtime.configuration
        Task {
            do {
                try await fileIO.run {
                    let data = try KeyboardMapArchive.encode(candidate)
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
                SystemIntegration.alert("快捷键导出失败", error.localizedDescription)
            }
        }
    }
}
