import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：明确选择独立配置目标后才编码和保存，导出不改变当前应用偏好。
    /// 参数说明: 无。
    /// 返回：用户确认的目标进入受保护写入，取消不发布文件。
    func chooseUserConfigurationExport() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true, findWindow?.isEditingInput != true,
            userConfiguration.task == nil, userConfiguration.preview == nil,
            let url = SystemIntegration.chooseSave(name: "Nate.nateconfig", directory: fileDialogDirectory())
        else {
            return
        }
        exportUserConfiguration(to: url)
    }

    /// 业务作用：当前完整配置固定为一次导出快照，原目标基线与工作区占用先于受登记的原子文件发布。
    /// 参数说明:
    /// - url: 用户明确确认的独立配置文件目标。
    /// 返回：全部字段有效且目标仍可写时保存完整归档，失败保留原目标和当前偏好。
    func exportUserConfiguration(to url: URL) {
        let runtime = userConfiguration
        guard !closing, runtime.task == nil, runtime.preview == nil else {
            return
        }
        let candidate: UserConfiguration
        do {
            candidate = try exportableUserConfiguration()
        }
        catch {
            runtime.failure = "配置导出未开始：" + error.localizedDescription
            refreshUI()
            return
        }
        let request = UUID(), generation = UUID(), token = CancellationToken()
        let access = fileAccess, operations = fileOperations
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
                try await withTaskCancellationHandler {
                    let prepared = try await runtime.io.run {
                        try token.check()
                        try FileStorage.validateFileURL(url)
                        let data = try UserConfigurationArchive.encode(
                            candidate,
                            permit: {
                                !token.isCancelled
                            }
                        )
                        let baseline =
                            FileManager.default.fileExists(atPath: url.path)
                            ? try access.baseline(
                                url,
                                permit: {
                                    !token.isCancelled
                                }
                            ) : nil
                        let path =
                            baseline?.resolvedPath ?? url.resolvingSymlinksInPath().standardizedFileURL.path
                        try token.check()
                        return (data, baseline, path)
                    }
                    guard let self, !self.closing, !Task.isCancelled, !token.isCancelled,
                        runtime.operation == request, runtime.generation == generation
                    else {
                        throw CancellationError()
                    }
                    // 活动或待连接文档持有自己的写入权，配置导出不能成为同一文件及硬链接别名的第二个写入者。
                    guard
                        !self.documents.contains(where: {
                            document in
                            document.url?.standardizedFileURL.path == prepared.2
                                || [document.baseline, document.pendingOriginalBaseline].compactMap {
                                    $0
                                }.contains {
                                    baseline in
                                    baseline.resolvedPath == prepared.2
                                        || prepared.1.map {
                                            $0.device == baseline.device && $0.inode == baseline.inode
                                        } == true
                                }
                        })
                    else {
                        throw NateError.message("配置导出目标由当前工作区文档持有，请选择独立文件。")
                    }
                    let owner = UUID()
                    guard self.reserveTarget(prepared.2, owner: owner) else {
                        throw NateError.message("配置导出目标仍有其它文件动作。")
                    }
                    defer {
                        self.releaseTarget(prepared.2, owner: owner)
                    }
                    _ = try await runtime.io.run {
                        try token.check()
                        return try operations.save(
                            using: access,
                            prepared.0,
                            to: url,
                            expected: prepared.1,
                            replacing: true,
                            permit: {
                                !token.isCancelled
                            },
                            authority: token
                        )
                    }
                } onCancel: {
                    token.cancel()
                }
                guard !Task.isCancelled, runtime.operation == request, runtime.generation == generation else {
                    return
                }
                runtime.failure = nil
                self?.mainWindow?.status.stringValue = "完整用户配置已导出 · " + url.lastPathComponent
            }
            catch is CancellationError {
                return
            }
            catch {
                guard !Task.isCancelled, runtime.operation == request, runtime.generation == generation else {
                    return
                }
                runtime.failure = "配置导出未确认：" + error.localizedDescription
            }
        }
        mainWindow?.status.stringValue = "正在准备完整用户配置导出，可在设置菜单取消。"
    }
}
