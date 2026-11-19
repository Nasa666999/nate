import AppKit
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：运行配置导入只读取用户明确选择的文件，完整列表先预览再决定是否替换。
    /// 参数说明: 无。
    /// 返回：选择文件后开始独立只读解析，取消保持现有配置。
    func chooseRunCommandImport() {
        guard canChangeRunCommands(), runCommands.importCandidate == nil else {
            return
        }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.message = "完整读取并预览运行配置，不执行其中程序。"
        guard chooser.runModal() == .OK, let url = chooser.url else {
            return
        }
        importRunCommands(url)
    }

    /// 业务作用：完整归档解析先于预览，关闭、取消或后来配置改变使旧读取失去替换资格。
    /// 参数说明:
    /// - url: 用户明确选择的普通运行归档。
    /// 返回：当前请求仍有效时安装完整只读候选；损坏、未知、超量或取消保留当前实际列表。
    func importRunCommands(_ url: URL) {
        let runtime = runCommands
        guard canChangeRunCommands(), runtime.importCandidate == nil else {
            return
        }
        cancelRunCommandPreparation()
        let request = UUID(), generation = runtime.generation
        let token = CancellationToken(), access = fileAccess
        runtime.importID = request
        runtime.importGeneration = request
        runtime.importTask = Task {
            [weak self] in
            defer {
                if runtime.importID == request {
                    runtime.importTask = nil
                    runtime.importID = nil
                }
                self?.refreshRunCommandPresentation()
            }
            do {
                let library = try await withTaskCancellationHandler {
                    try await runtime.io.run {
                        let bytes = try access.readData(
                            url,
                            maximumBytes: RunCommandArchive.maximumBytes,
                            permit: {
                                !token.isCancelled
                            }
                        ).data
                        return try RunCommandArchive.decode(
                            bytes,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                } onCancel: {
                    token.cancel()
                }
                // 只读归档不拥有后来列表或已关闭窗口的替换权，载入完成也不能启动外部程序。
                guard let self, !self.closing, !Task.isCancelled,
                    runtime.importGeneration == request, runtime.generation == generation
                else {
                    return
                }
                runtime.importCandidate = library
                runtime.importName = url.lastPathComponent
                runtime.preparationFailure = nil
            }
            catch is CancellationError {
                return
            }
            catch {
                guard !Task.isCancelled, runtime.importGeneration == request else {
                    return
                }
                runtime.preparationFailure = "导入尚未应用：" + error.localizedDescription
            }
        }
        refreshRunCommandPresentation()
    }

    /// 业务作用：取消导入立即收回预览发布资格，实际系统读取仍保留原任务占用直到返回。
    /// 参数说明: 无。
    /// 返回：释放未应用候选，不改写实际配置和命令菜单。
    func cancelRunCommandImport() {
        let runtime = runCommands
        runtime.importGeneration = UUID()
        runtime.importTask?.cancel()
        runtime.importCandidate = nil
        runtime.importName = nil
        refreshRunCommandPresentation()
    }

    /// 业务作用：导出保存完整实际列表或完整导入候选，不把尚未保存的表单字段混入归档。
    /// 参数说明: 无。
    /// 返回：目标基线复验后保存完整归档，取消或失败不改变当前库或执行程序。
    func exportRunCommands() {
        let runtime = runCommands
        guard !closing, runtime.ready, runtime.task == nil, runtime.importTask == nil,
            let url = SystemIntegration.chooseSave(name: "Nate.nateruns")
        else {
            return
        }
        let library = runtime.importCandidate ?? runtime.library
        Task {
            do {
                try await fileIO.run {
                    let data = try RunCommandArchive.encode(library)
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
                SystemIntegration.alert("运行配置导出失败", error.localizedDescription)
            }
        }
    }
}
