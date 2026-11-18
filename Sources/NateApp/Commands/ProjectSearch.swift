import AppKit
import NateCore
import NateSearch
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：搜索界面只展示已载入且当前没有定义动作的项目面板，隐藏树不等于卸载定义。
    /// 参数说明: 无。
    /// 返回：可用面板选择同步，不解释引用路径或触发磁盘读取。
    func refreshProjectSearchAvailability() {
        findWindow?.setAvailableProjectPanels(
            projectPanelStates.indices.filter {
                projectPanelStates[$0].workspace != nil && projectPanelStates[$0].operation == nil
            }
        )
    }

    /// 业务作用：固定用户勾选的真实项目集合，逐项解释引用并在任何卷访问前取得明确选择。
    /// 参数说明:
    /// - filters: 实际文件名包含与排除原文。
    /// - options: 本次完整查找替换条件。
    /// - replacing: 是否在完整预览确认后修改所选集合。
    /// 返回：只有原面板、定义和条件仍有效才开始读取；未知或未授权引用逐项反馈。
    func searchProjects(filters: String, options: SearchOptions, replacing: Bool) {
        refreshProjectSearchAvailability()
        guard let findWindow else {
            return
        }
        let indices = findWindow.selectedProjectPanels
        guard !indices.isEmpty else {
            findWindow.feedback.stringValue = "请勾选至少一个已载入且可用的项目面板。"
            return
        }
        let generation = queryGeneration
        let definitions = indices.map {
            projectPanelStates[$0].generation
        }
        let identity = findWindow.projectRequestIdentity
        let inputs = findWindow.inputIdentities
        let current: @MainActor () -> Bool = {
            [weak self, weak findWindow] in
            guard let self, let findWindow, !self.closing,
                self.queryGeneration == generation, self.findWindow === findWindow,
                findWindow.matchesProjectRequest(
                    options: options,
                    filters: filters,
                    panels: indices,
                    identity: identity,
                    inputs: inputs
                )
            else {
                return false
            }
            return zip(indices, definitions).allSatisfy {
                index,
                definition in
                self.projectPanelStates[index].generation == definition
                    && self.projectPanelStates[index].workspace != nil
                    && self.projectPanelStates[index].operation == nil
            }
        }
        let captures = indices.compactMap {
            index -> ProjectSearchPanelCapture? in
            let state = projectPanelStates[index]
            guard let workspace = state.workspace else {
                return nil
            }
            return ProjectSearchPanelCapture(
                index: index,
                workspace: workspace,
                definitionPath: state.url?.path,
                selectedPaths: state.selectedPaths
            )
        }
        searchFiles(
            source: .projectReferences(captures),
            filters: filters,
            options: options,
            replacing: replacing,
            current: current
        )
    }

    /// 业务作用：后台只解释原始引用，明确位置许可之后才建立真正可读取的项目文件集合。
    /// 参数说明:
    /// - source: 固定目录或尚未解释的项目定义快照。
    /// - filters: 当前完整文件名过滤条件。
    /// - current: 原面板、定义和输入是否仍然有效。
    /// 返回：已授权的完整读取集合；取消、失权或非法范围不产生文件探测和读取。
    func authorizeFileSearchSource(
        _ source: FileSearchSource,
        filters: String,
        current: @escaping @MainActor () -> Bool
    ) async throws -> FileSearchSource {
        guard case .projectReferences(let captures) = source else {
            return source
        }
        let resolved = try await readIO.readCancellable {
            token in
            try ProjectSearchReferenceResolver.resolve(captures, filters: filters, token: token)
        }
        try Task.checkCancellation()
        // 路径计算不能授予文件访问权，已改变的范围在任何位置确认和实际访问前立即失效。
        guard current() else {
            throw CancellationError()
        }
        var failures = resolved.failures
        var includeVolumes = false
        let pendingVolumes = resolved.references.filter {
            $0.needsConsent
        }
        if !pendingVolumes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "访问项目引用中的外置或网络卷？"
            alert.informativeText =
                "\(pendingVolumes.count) 个引用的位置尚未检查。只有选择访问后才进行类型探测和正文读取。\n"
                + pendingVolumes.prefix(8).map {
                    ProjectSearchReferenceResolver.label($0.path)
                }.joined(separator: "\n")
            alert.addButton(withTitle: "访问这些引用")
            alert.addButton(withTitle: "跳过这些引用")
            alert.addButton(withTitle: "取消搜索")
            // 卷访问的资格仅属于本次完整固定范围，嵌套事件循环之后必须重新验证所有定义。
            let choice = alert.runModal()
            guard current(), !Task.isCancelled else {
                throw CancellationError()
            }
            if choice == .alertFirstButtonReturn {
                includeVolumes = true
            }
            else if choice == .alertSecondButtonReturn {
                failures.append(
                    contentsOf: pendingVolumes.map {
                        ProjectSearchReferenceResolver.label($0.path) + "：未授权访问，位置尚未检查。"
                    }
                )
            }
            else {
                throw NateError.message("已取消项目搜索，引用文件尚未读取。")
            }
        }
        // 未经当前面板、条件及卷选择授权，不构造目标文件 URL，也不进入统一文件访问入口。
        guard current(), !Task.isCancelled else {
            throw CancellationError()
        }
        let files = resolved.references.filter {
            includeVolumes || !$0.needsConsent
        }.map {
            URL(fileURLWithPath: $0.path, isDirectory: false)
        }
        return .projects(
            files: files,
            failures: failures,
            panels: captures.map {
                $0.index
            }
        )
    }
}
