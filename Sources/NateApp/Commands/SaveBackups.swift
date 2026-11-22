import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

private struct SaveBackupConfiguration: Codable {
    var format = 1
    let policy: SaveBackupPolicy
}

extension ApplicationController {
    /// 业务作用：保存备份配置独立于恢复开关加载，未知格式不能默默退回无备份覆盖。
    /// 参数说明: 无。
    /// 返回：发布可解释的策略，配置损坏时保留原配置并阻止后续原文件写入。
    func loadSaveBackupPolicy() {
        saveBackupPolicy = SaveBackupPolicy()
        saveBackupSettingsError = nil
        guard let value = configurationDefaults().object(forKey: "saveBackupPolicy") else {
            return
        }
        do {
            guard let bytes = value as? Data else {
                throw NateError.message("保存备份配置不是可识别的数据。")
            }
            let configuration = try JSONDecoder().decode(SaveBackupConfiguration.self, from: bytes)
            guard configuration.format == 1 else {
                throw NateError.message("保存备份配置格式尚不可解释。")
            }
            try configuration.policy.validate()
            saveBackupPolicy = configuration.policy
            saveBackupSettingsError = nil
        }
        catch {
            saveBackupSettingsError = error.localizedDescription
        }
    }

    /// 业务作用：一次保存固定一份备份策略和派生权限，设置变更不改变已经在途的保存。
    /// 参数说明:
    /// - request: 当前原文件或另存目标的登记请求。
    /// 返回：已启用时返回固定请求，关闭时为空；不可解释配置不授权覆盖。
    func saveBackupRequest(_ request: FileOperationRequest) throws -> SaveBackupRequest? {
        // 未知配置可能原本要求保护历史，不能按默认关闭继续覆盖用户文件。
        if let saveBackupSettingsError {
            throw NateError.message("请先检查保存时备份设置：" + saveBackupSettingsError)
        }
        guard saveBackupPolicy.mode != .disabled else {
            return nil
        }
        guard let saveBackupStore else {
            throw NateError.message("保存备份目录尚不可用，原文件覆盖已停止。")
        }
        return SaveBackupRequest(
            store: saveBackupStore,
            policy: saveBackupPolicy,
            authority: request.permission
        )
    }

    /// 业务作用：通过明确配置选择保存前历史及清理边界，不改变独立恢复保护的开关。
    /// 参数说明: 无。
    /// 返回：应用后策略用于后续保存，取消保留原配置及全部历史。
    func showSaveBackupPreferences() {
        let alert = NSAlert()
        alert.messageText = "保存时备份"
        alert.informativeText =
            "覆盖已有原文件或另存目标前保存原始字节，备份失败会停止覆盖。数量、期限和去重总容量在后续保存时共同生效；关闭备份会保留已有历史。发布新内容期间需要额外临时空间。"
        if let saveBackupSettingsError {
            alert.informativeText += "\n现有配置无法解释：" + saveBackupSettingsError + "\n点击应用将采用下方设置。"
        }
        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["关闭", "保留上一份", "保留多份"])
        mode.selectItem(at: SaveBackupMode.allCases.firstIndex(of: saveBackupPolicy.mode) ?? 0)
        mode.setAccessibilityLabel("保存备份模式")
        let versions = NSTextField(string: String(saveBackupPolicy.versionsPerFile))
        versions.setAccessibilityLabel("每个文件最多保留份数")
        let days = NSTextField(string: String(saveBackupPolicy.retentionDays))
        days.setAccessibilityLabel("备份保留天数")
        let capacity = NSTextField(string: String(saveBackupPolicy.maximumBytes / 1_048_576))
        capacity.setAccessibilityLabel("备份总容量 MiB")
        let view = NSStackView(views: [
            NSTextField(labelWithString: "保存前历史"), mode,
            NSTextField(labelWithString: "多份模式每文件上限（1–1000）"), versions,
            NSTextField(labelWithString: "保留天数（1–3650）"), days,
            NSTextField(labelWithString: "去重总容量 MiB（1–1048576）"), capacity,
        ])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 7
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 248)
        for field in [versions, days, capacity] {
            field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            guard SaveBackupMode.allCases.indices.contains(mode.indexOfSelectedItem),
                let count = Int(versions.stringValue), let retention = Int(days.stringValue),
                let mebibytes = Int64(capacity.stringValue), (1...1_048_576).contains(mebibytes)
            else {
                throw NateError.message("请填写范围内的整数，现有配置保持原状。")
            }
            let policy = SaveBackupPolicy(
                mode: SaveBackupMode.allCases[mode.indexOfSelectedItem],
                versionsPerFile: count,
                retentionDays: retention,
                maximumBytes: mebibytes * 1_048_576
            )
            try policy.validate()
            let bytes = try JSONEncoder().encode(SaveBackupConfiguration(policy: policy))
            configurationDefaults().set(bytes, forKey: "saveBackupPolicy")
            saveBackupPolicy = policy
            saveBackupSettingsError = nil
            mainWindow?.status.stringValue = "保存备份设置已应用；后续保存按新策略保留历史。"
        }
        catch {
            SystemIntegration.alert("保存备份设置未应用", error.localizedDescription)
        }
    }

    /// 业务作用：展示可检查的原文件历史，界面打开动作始终建立独立文档。
    /// 参数说明: 无。
    /// 返回：显示可筛选列表，并在后台读取当前可靠索引。
    func showSavedBackups() {
        if savedBackupsWindow == nil {
            let window = SavedBackupsWindow(encodings: TextEncoding.available.map(\.name))
            window.onRefresh = {
                [weak self] in
                self?.refreshSavedBackups()
            }
            window.onOpen = {
                [weak self] id, encoding in
                Task {
                    await self?.openSavedBackup(id, encodingIndex: encoding)
                }
            }
            savedBackupsWindow = window
        }
        savedBackupsWindow?.showWindow(nil)
        savedBackupsWindow?.window?.makeKeyAndOrderFront(nil)
        refreshSavedBackups()
    }

    /// 业务作用：历史刷新有独立请求身份，较早返回的列表不能覆盖后来的选择范围。
    /// 参数说明: 无。
    /// 返回：后台读取并发布最新历史，失败显示原因且保留已有展示。
    func refreshSavedBackups() {
        guard !closing, let store = saveBackupStore else {
            return
        }
        backupBrowserTask?.cancel()
        let generation = UUID()
        backupBrowserGeneration = generation
        savedBackupsWindow?.showStatus("正在读取保存前的备份…")
        backupBrowserTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if backupBrowserGeneration == generation {
                    backupBrowserTask = nil
                }
            }
            do {
                let records = try await readIO.readCancellable {
                    token in
                    try store.list(permit: {
                        !token.isCancelled
                    })
                }
                // 退出接管工作区或新刷新已经开始后，旧读取不能发布新的历史选择。
                guard !closing, backupBrowserGeneration == generation else {
                    return
                }
                savedBackupRecords = records
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                savedBackupsWindow?.update(
                    records.map {
                        SavedBackupPresentation(
                            id: $0.id,
                            path: $0.originalPath,
                            timestamp: formatter.string(from: $0.created),
                            size: ByteCountFormatter.string(fromByteCount: $0.byteCount, countStyle: .file)
                        )
                    },
                    message: "选择编码后作为新文档打开，检查内容后可另存为。"
                )
            }
            catch {
                if backupBrowserGeneration == generation {
                    savedBackupsWindow?.showStatus("历史读取未完成：" + error.localizedDescription)
                }
            }
        }
    }

    /// 业务作用：将用户选择的历史原字节解码为独立正文，原路径和历史记录均不取得自动写入绑定。
    /// 参数说明:
    /// - id: 当前历史列表中的稳定内容身份。
    /// - encodingIndex: 用户明确选择的代码页序号，为空时自动识别。
    /// 返回：验证和解码成功后建立可恢复新文档；失败保留全部原字节。
    func openSavedBackup(_ id: String, encodingIndex: Int?) async {
        guard !closing, let store = saveBackupStore,
            let record = savedBackupRecords.first(where: {
                $0.id == id
            })
        else {
            return
        }
        let encoding = encodingIndex.flatMap {
            TextEncoding.available.indices.contains($0) ? TextEncoding.available[$0] : nil
        }
        let catalog = codecs
        do {
            let loaded = try await readIO.readCancellable {
                token in
                let bytes = try store.read(
                    record,
                    maximumBytes: RecoveryLimits.documentBytes,
                    permit: {
                        !token.isCancelled
                    }
                )
                let decoded = try TextEncoding.detect(bytes, explicit: encoding, catalog: catalog)
                guard !token.isCancelled else {
                    throw CancellationError()
                }
                return (
                    text: decoded.0, encoding: decoded.1, tree: PieceTree(decoded.0),
                    ending: LineEnding.detect(decoded.0)
                )
            }
            // 文件等待期间退出可能已经固定成员集合，迟到历史不能创建未受最终索引保护的新标签。
            guard !closing else {
                return
            }
            let name = URL(fileURLWithPath: record.originalPath).lastPathComponent
            let document = WorkspaceDocument(
                name: name + "（保存备份）",
                text: loaded.text,
                textTree: loaded.tree,
                encoding: loaded.encoding,
                lineEnding: loaded.ending
            )
            document.language =
                registry?.detect(filename: name, firstLine: String(loaded.text.prefix(4096))) ?? "normal"
            document.state = "保存前历史 · 尚未选择原文件"
            documents.append(document)
            activate(document.buffer.id)
            mainWindow?.window?.makeKeyAndOrderFront(nil)
            buildMenus()
        }
        catch is CancellationError {
            return
        }
        catch {
            SystemIntegration.alert("无法打开保存备份", error.localizedDescription + "\n可以选择明确编码后重试，原始字节保持可用。")
        }
    }
}
