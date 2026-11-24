import AppKit
import NateCore
import NateStorage

extension ApplicationController {
    /// 业务作用：用户明确选择配置文件后才开始只读解析，文件内容不会在读取完成时自动应用。
    /// 参数说明: 无。
    /// 返回：确认的普通文件进入有界读取，取消不创建候选或改变偏好。
    func chooseUserConfigurationImport() {
        guard canApplyUserConfiguration(), userConfiguration.task == nil, userConfiguration.preview == nil
        else {
            return
        }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.message = "选择 Nate 用户配置，完整读取后先预览，确认前不改变当前设置。"
        chooser.directoryURL = fileDialogDirectory()
        guard chooser.runModal() == .OK, let url = chooser.url else {
            return
        }
        importUserConfiguration(url)
    }

    /// 业务作用：完整读取、容器摘要及各项语义检查先于预览，迟到结果不能取得后来偏好的替换权。
    /// 参数说明:
    /// - url: 用户明确选择的原始配置文件 URL。
    /// 返回：来源未变时展示完整待确认配置；取消、关闭、无效或来源变化时保留原域。
    func importUserConfiguration(_ url: URL) {
        let runtime = userConfiguration
        guard canApplyUserConfiguration(), runtime.task == nil, runtime.preview == nil else {
            return
        }
        let source: UserConfiguration
        do {
            source = try configurationSource()
        }
        catch {
            runtime.failure = "配置导入未开始：" + error.localizedDescription
            refreshUI()
            return
        }
        let request = UUID(), generation = UUID(), proof = configurationGenerationProof()
        let domain = configurationDefaults(), access = fileAccess
        runtime.generation = generation
        runtime.operation = request
        runtime.failure = nil
        runtime.task = Task {
            [weak self] in
            defer {
                if runtime.operation == request {
                    runtime.task = nil
                    runtime.operation = nil
                }
                self?.refreshUI()
            }
            do {
                let candidate = try await runtime.io.readCancellable {
                    token -> UserConfiguration in
                    try FileStorage.validateFileURL(url)
                    let bytes = try access.readData(
                        url,
                        maximumBytes: UserConfigurationArchive.maximumBytes,
                        permit: {
                            !token.isCancelled
                        }
                    ).data
                    let decoded = try UserConfigurationArchive.decode(
                        bytes,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let configuration = try UserConfigurationSchema.preservingAddedPreferences(
                        decoded,
                        source: source
                    )
                    try UserConfigurationSchema.validate(
                        configuration,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    try token.check()
                    return configuration
                }
                guard let self, !self.closing, !Task.isCancelled, runtime.operation == request,
                    runtime.generation == generation
                else {
                    return
                }
                // 文件读取没有当前偏好的覆盖权限，域、原字段和业务代次均须保持原来源。
                guard self.configurationDefaults() === domain, try self.configurationSource() == source,
                    self.configurationGenerationProof() == proof
                else {
                    throw NateError.message("读取期间当前偏好已改变，导入未应用，请重新选择配置。")
                }
                try self.stageUserConfiguration(candidate, name: url.lastPathComponent)
                try self.showUserConfigurationPreview()
            }
            catch is CancellationError {
                return
            }
            catch {
                guard !Task.isCancelled, runtime.operation == request, runtime.generation == generation else {
                    return
                }
                runtime.failure = "配置导入未应用：" + error.localizedDescription
                self?.clearUserConfigurationPreview()
            }
        }
        mainWindow?.status.stringValue = "正在读取用户配置，确认前保持当前设置。"
    }

    /// 业务作用：取消只撤销尚未完成的配置动作权限，实际 I/O 与文件登记保留到真实返回。
    /// 参数说明: 无。
    /// 返回：旧读取不能发布预览，未使用写入权被撤销；已完成的文件发布仍保留。
    func cancelUserConfigurationOperation() {
        let runtime = userConfiguration
        runtime.generation = UUID()
        runtime.task?.cancel()
        if let window = runtime.previewWindow, NSApp?.modalWindow === window {
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
        clearUserConfigurationPreview()
        if runtime.task != nil {
            runtime.failure = "已请求取消配置操作，已完成的文件发布仍保留。"
        }
    }
}
