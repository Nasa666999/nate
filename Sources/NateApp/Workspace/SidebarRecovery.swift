import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class SidebarRecoveryRuntime {
    let io = IOExecutor(name: "nate.sidebar.recovery", concurrency: 1, maximumStalled: 0)
    var generation = UUID()
    var loading = false
    var ready = false
    var baseline: DiskBaseline?
    var lastSaved: SidebarRecoveryState?
    var lastAttempt: SidebarRecoveryState?
    var pending: SidebarRecoveryState?
    var task: Task<Void, Never>?
    var failure: String?

    /// 业务作用：侧栏保护拥有独立排队和磁盘证据，不占用正文恢复或原文件保存的执行通道。
    /// 参数说明: 无。
    /// 返回：尚未取得归档读取和覆盖资格的初始状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：捕获真实侧栏状态，退出时遵守已确认的放弃定义意图，不改写仍留在内存的草稿。
    /// 参数说明:
    /// - discardingDrafts: 是否仅保留各面板已确认的保存点，正常退出保护使用此值。
    /// 返回：当前定义、保存点、根目录和树状态的完整纯数据快照，没有主窗口时为空。
    func captureSidebarState(discardingDrafts: Bool = false) -> SidebarRecoveryState? {
        guard let window = mainWindow else {
            return nil
        }
        let projects = projectPanelStates.indices.map {
            index -> SidebarProjectSnapshot in
            let state = projectPanelStates[index]
            let workspace = discardingDrafts ? state.saved : state.workspace
            guard let workspace else {
                return SidebarProjectSnapshot()
            }
            let panel = window.projectPanels.panels[index]
            let identities = Set(workspace.nodes.map(\.id))
            let folders = Set(
                workspace.nodes.filter {
                    $0.kind != .file
                }.map(\.id)
            )
            return SidebarProjectSnapshot(
                workspace: workspace,
                saved: state.saved,
                definitionPath: state.url?.path,
                baseline: state.baseline,
                saveBlocked: state.saveBlocked,
                expanded: panel.expandedNodes.filter {
                    folders.contains($0)
                },
                selected: panel.selectedNode.flatMap {
                    identities.contains($0) ? $0 : nil
                }
            )
        }
        let directory = directoryWorkspace?.window === window ? directoryWorkspace?.sidebarSnapshot : nil
        return SidebarRecoveryState(
            projects: projects,
            selectedProject: window.projectPanels.selectedIndex,
            projectsVisible: !window.projectPanels.isHidden,
            directory: directory
        )
    }

    /// 业务作用：启动恢复侧栏纯数据，旧读取只能作用于原窗口和仍未改变的三个定义。
    /// 参数说明: 无。
    /// 返回：完整归档一次还原；损坏或迟到读取保留原界面并停止自动覆盖，目录和项目引用不会被自动打开。
    func loadSidebarRecovery() async {
        guard let store = recovery, let window = mainWindow, !closing,
            projectPanelStates.allSatisfy({
                $0.operation == nil
            })
        else {
            return
        }
        let runtime = sidebarRecovery
        guard !runtime.loading, runtime.task == nil else {
            return
        }
        // 先撤销旧读取身份并关闭自动覆盖资格，未知归档不能因读取失败变成可覆盖的空初始状态。
        runtime.generation = UUID()
        let request = runtime.generation
        let projects = projectPanelStates.map(\.generation)
        let originalDirectory = directoryWorkspace?.sidebarSnapshot
        let directoryGeneration = directoryWorkspace?.sidebarGeneration
        let projectNavigation = projectOpenGeneration
        runtime.loading = true
        runtime.ready = false
        defer {
            if runtime.generation == request {
                runtime.loading = false
            }
        }
        do {
            let restored = try await runtime.io.readCancellable {
                token in
                try store.restoreSidebars(permit: {
                    !token.isCancelled
                })
            }
            // 相同应用对象不足以恢复旧读取权，窗口、定义和目录根的任何变化都优先于归档结果。
            guard !closing, !Task.isCancelled, runtime.generation == request,
                mainWindow === window, projectPanelStates.map(\.generation) == projects,
                projectPanelStates.allSatisfy({
                    $0.operation == nil
                }),
                projectOpenGeneration == projectNavigation,
                directoryWorkspace?.sidebarGeneration == directoryGeneration,
                directoryWorkspace?.sidebarSnapshot == originalDirectory
            else {
                if runtime.generation == request {
                    runtime.failure = "侧栏已改变，未应用旧恢复状态；自动覆盖保持停止。"
                }
                return
            }
            if let state = restored.state {
                try applySidebarState(state, in: window)
            }
            runtime.baseline = restored.baseline
            runtime.lastSaved = restored.state
            runtime.lastAttempt = nil
            runtime.ready = restored.writable
            runtime.failure = restored.warning
        }
        catch {
            guard runtime.generation == request else {
                return
            }
            runtime.failure = "侧栏未恢复，原归档保留；可重新保存当前侧栏：" + error.localizedDescription
        }
    }

    /// 业务作用：完整侧栏数据先验证再发布，原定义路径只供显示，不复活未核验的覆盖权限。
    /// 参数说明:
    /// - snapshot: 已取得的完整侧栏快照。
    /// - window: 仍属于当前工作区的原生窗口。
    /// 返回：三个定义与树状态整体恢复，原目录只显示待连接根，正文、焦点和搜索输入保持原状。
    func applySidebarState(_ snapshot: SidebarRecoveryState, in window: EditorWindow) throws {
        try snapshot.validate()
        guard !closing, mainWindow === window,
            projectPanelStates.allSatisfy({
                $0.operation == nil
            })
        else {
            return
        }
        cancelProjectOpen()
        for index in projectPanelStates.indices {
            cancelProjectSearch(changing: index)
            let state = projectPanelStates[index], restored = snapshot.projects[index]
            // 恢复定义本身不重新取得原路径写入权，后续需显式重新载入或确认另存目标。
            state.generation = UUID()
            state.workspace = restored.workspace
            state.saved = restored.saved
            state.url = restored.definitionPath.map {
                URL(fileURLWithPath: $0)
            }
            state.baseline = restored.baseline
            state.saveBlocked = restored.saveBlocked || restored.definitionPath != nil
            state.selectedPaths.removeAll()
            state.feedback =
                restored.workspace == nil
                ? "尚未载入工作区。"
                : state.url == nil
                    ? "项目定义已恢复；引用文件尚未检查。"
                    : "项目定义已恢复；原定义路径未取得写入权，请重新载入或另存为。"
        }
        for index in projectPanelStates.indices {
            refreshProjectPanel(index)
            let restored = snapshot.projects[index]
            window.projectPanels.panels[index].restoreTreeState(
                expanded: restored.expanded,
                selected: restored.selected
            )
        }
        window.setProjectsVisible(snapshot.projectsVisible, selected: snapshot.selectedProject)
        if let directory = snapshot.directory {
            if directoryWorkspace?.window !== window {
                directoryWorkspace?.stop()
                directoryWorkspace = DirectoryWorkspaceController(application: self, window: window)
            }
            try directoryWorkspace?.restoreSidebar(directory)
        }
        else {
            directoryWorkspace?.stop()
        }
    }
}
