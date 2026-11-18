import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：项目动作跨越等待或模态界面后复验当前面板的实际处理资格。
    /// 参数说明:
    /// - index: 目标独立面板索引。
    /// - operation: 本次动作的唯一身份。
    /// 返回：应用未退出、面板存在且仍由该动作持有时为真。
    func projectOperationCurrent(_ index: Int, operation: UUID) -> Bool {
        !closing && projectPanelStates.indices.contains(index)
            && projectPanelStates[index].operation == operation
    }

    /// 业务作用：只载入完整项目定义和磁盘基线，引用路径的存在性或网络位置不在载入期间探测。
    /// 参数说明:
    /// - index: 已取得处理资格的独立面板。
    /// - url: 用户明确选择的原始定义文件 URL。
    /// - operation: 当前动作身份。
    /// 返回：全部解码通过且处理资格仍有效才替换原定义；失败保留原内存定义及磁盘字节。
    func loadProjectDefinition(_ index: Int, from url: URL, operation: UUID) async throws {
        let (workspace, baseline) = try await readIO.readCancellable {
            token in
            let loaded = try self.fileAccess.readData(
                url,
                maximumBytes: 8 * 1024 * 1024,
                permit: {
                    !token.isCancelled
                }
            )
            let workspace = try ProjectWorkspaceArchive.decode(loaded.data)
            try token.check()
            return (workspace, loaded.baseline)
        }
        // 读取只是计算证据，旧动作在退出或被替换后不能取得新面板的定义发布权。
        guard projectOperationCurrent(index, operation: operation) else {
            return
        }
        let state = projectPanelStates[index]
        cancelProjectOpen()
        state.generation = UUID()
        state.workspace = workspace
        state.saved = workspace
        state.url = url
        state.baseline = baseline
        state.selectedPaths.removeAll()
        state.saveBlocked = false
        state.feedback = "已载入 \(workspace.files.count) 个文件引用；引用可用性尚未检查。"
    }

    /// 业务作用：按固定原基线保存完整项目定义，面板保存和正文保存不能同时覆盖同一实际文件。
    /// 参数说明:
    /// - index: 当前独立面板。
    /// - operation: 仍持有面板的动作身份。
    /// - forceSaveAs: 是否要求用户重新选择并确认目标。
    /// - explicitTarget: 已由调用方明确选择的目标，为空时使用当前绑定或系统保存对话框。
    /// 返回：确认写入后为真，取消或失权为假；实际失败保留内存定义并停止普通重试。
    func saveProjectDefinition(
        _ index: Int,
        operation: UUID,
        forceSaveAs: Bool = false,
        explicitTarget: URL? = nil
    ) async throws -> Bool {
        guard projectOperationCurrent(index, operation: operation),
            let workspace = projectPanelStates[index].workspace
        else {
            return false
        }
        let state = projectPanelStates[index]
        // 恢复后未复验原路径或保存结果不明时不重新使用旧基线，必须显式载入定义或重新确认另存目标。
        guard !state.saveBlocked || forceSaveAs || explicitTarget != nil else {
            throw NateError.message("当前定义路径尚未取得覆盖资格，请重新载入定义或使用“工作区另存为”。")
        }
        let choosing = forceSaveAs || state.url == nil || explicitTarget != nil
        let target: URL
        if let explicitTarget {
            target = explicitTarget
        }
        else if choosing {
            guard
                let chosen = SystemIntegration.chooseSave(
                    name: state.url?.lastPathComponent ?? "Workspace.nateworkspace"
                )
            else {
                state.feedback = "已取消保存，当前项目定义保留。"
                return false
            }
            target = chosen
        }
        else if let bound = state.url {
            target = bound
        }
        else {
            return false
        }
        // 系统对话框可运行嵌套事件循环，选择返回不等于原面板仍由本动作持有。
        guard projectOperationCurrent(index, operation: operation) else {
            return false
        }
        let originalBaseline = state.baseline
        let (data, expected, path) = try await readIO.readCancellable {
            token -> (Data, DiskBaseline?, String) in
            try token.check()
            try FileStorage.validateFileURL(target)
            let data = try ProjectWorkspaceArchive.encode(workspace)
            let expected: DiskBaseline?
            if choosing {
                expected =
                    FileManager.default.fileExists(atPath: target.path)
                    ? try self.fileAccess.baseline(
                        target,
                        permit: {
                            !token.isCancelled
                        }
                    ) : nil
            }
            else {
                expected = originalBaseline
            }
            let path = expected?.resolvedPath ?? target.resolvingSymlinksInPath().standardizedFileURL.path
            try token.check()
            return (data, expected, path)
        }
        guard projectOperationCurrent(index, operation: operation) else {
            return false
        }
        // 定义文件若同时作为正文打开，两条独立写入通道会形成竞争；同路径和同 inode 均必须拒绝。
        guard
            !documents.contains(where: {
                document in
                if document.url?.path.utf8.elementsEqual(
                    target.path.utf8
                ) == true {
                    return true
                }
                guard let baseline = document.baseline else {
                    return false
                }
                if baseline.resolvedPath.utf8.elementsEqual(path.utf8) {
                    return true
                }
                return expected.map {
                    baseline.device == $0.device && baseline.inode == $0.inode
                } ?? false
            })
        else {
            throw NateError.message("工作区定义同时在正文标签中打开，请先关闭该标签或选择其他保存目标。")
        }
        let owner = UUID()
        // 路径占用先于实际写入登记，另存与其他文件动作不能同时取得同一目标。
        guard reserveTarget(path, owner: owner) else {
            throw NateError.message("项目定义目标正在执行其他文件动作。")
        }
        defer {
            releaseTarget(path, owner: owner)
        }
        do {
            let baseline = try await fileIO.runCancellable {
                token in
                try token.check()
                return try self.fileOperations.save(
                    using: self.fileAccess,
                    data,
                    to: target,
                    expected: expected,
                    replacing: choosing,
                    permit: {
                        !token.isCancelled
                    }
                )
            }
            // 实际发布确认后才更新保存点，未返回或失权结果不能把当前定义误记为已保存。
            guard projectOperationCurrent(index, operation: operation) else {
                return false
            }
            cancelProjectOpen()
            state.generation = UUID()
            state.saved = workspace
            state.url = target
            state.baseline = baseline
            state.saveBlocked = false
            state.feedback = "已保存完整项目定义；引用文件字节保持原状。"
            return true
        }
        catch {
            // 同步失败或发布结果不明不能沿旧基线自动重试，真实阶段仍保留在文件任务中。
            if projectOperationCurrent(index, operation: operation) {
                state.saveBlocked = true
                state.feedback = "项目定义保存未确认；当前定义保留，可重新载入或另存为，实际阶段见文件任务。"
            }
            throw error
        }
    }

    /// 业务作用：替换或卸载项目定义前让用户处理当前尚未保存的虚拟结构，磁盘引用始终保持原状。
    /// 参数说明:
    /// - index: 当前独立面板。
    /// - operation: 当前动作身份。
    /// 返回：没有变化、保存成功或用户明确选择不保存时为真；取消、失权或保存失败时保留原定义。
    func confirmProjectReplacement(_ index: Int, operation: UUID) async throws -> Bool {
        let state = projectPanelStates[index]
        guard state.isDirty else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "保存当前项目定义？"
        alert.informativeText = "当前虚拟结构与文件引用尚未写入工作区文件。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        // 确认只属于当前面板动作，不能沿嵌套事件循环中已失效的身份继续替换。
        guard projectOperationCurrent(index, operation: operation) else {
            return false
        }
        if choice == .alertFirstButtonReturn {
            return try await saveProjectDefinition(
                index,
                operation: operation,
                forceSaveAs: state.saveBlocked
            )
        }
        return choice == .alertSecondButtonReturn
    }
}
