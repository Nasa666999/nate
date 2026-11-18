import AppKit
import NateStorage
import NateUI

@MainActor
final class ProjectPanelState {
    var workspace: ProjectWorkspace?
    var saved: ProjectWorkspace?
    var url: URL? {
        didSet {
            let before = oldValue.map { Data($0.absoluteString.utf8) }
            let after = url.map { Data($0.absoluteString.utf8) }
            if before != after {
                // 定义目标变化立即撤销旧请求身份，改回原路径也不能恢复此前的覆盖资格。
                generation = UUID()
            }
        }
    }
    var baseline: DiskBaseline?
    var generation = UUID()
    var operation: UUID?
    var task: Task<Void, Never>?
    var feedback = "新建或载入工作区；引用文件的可用性尚未检查。"
    var saveBlocked = false
    var bindingNeedsVerification = false
    var selectedPaths: Set<Data> = []
    var isDirty: Bool {
        workspace != saved
    }

    /// 业务作用：每个项目面板独立持有定义、原保存点和当前动作，不借用会话或目录工作区状态。
    /// 参数说明: 无。
    /// 返回：尚未载入工作区且没有磁盘访问资格的面板状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：显式显示指定的独立项目面板，不自动创建项目或打开引用文件。
    /// 参数说明:
    /// - index: 从零开始的三个面板索引。
    /// 返回：有效面板显示其原定义、选择和展开状态，无效索引保持原界面。
    func showProjectPanel(_ index: Int) {
        // 退出已经固定工作区，项目面板不能重新取得打开文件和编辑定义的入口。
        guard !closing, projectPanelStates.indices.contains(index), let mainWindow else {
            return
        }
        refreshProjectPanel(index)
        mainWindow.setProjectsVisible(true, selected: index)
    }

    /// 业务作用：把当前完整定义映射为不含文件访问能力的展示值，保存状态变化不重新打开任何路径。
    /// 参数说明:
    /// - index: 需要同步的面板索引。
    /// - reveal: 用户明确新增或定位的节点，普通状态刷新为空。
    /// 返回：原面板完整更新；仅显式定位时展开并选择指定节点。
    func refreshProjectPanel(_ index: Int, reveal: UUID? = nil) {
        refreshProjectSearchAvailability()
        guard projectPanelStates.indices.contains(index), let mainWindow else {
            return
        }
        let state = projectPanelStates[index]
        let entries = state.workspace?.nodes.map {
            ProjectTreeEntry(
                id: $0.id,
                parent: $0.parent,
                name: $0.name,
                pathHint: $0.path
            )
        }
        let panel = mainWindow.projectPanels.panels[index]
        panel.present(
            name: state.url?.lastPathComponent ?? (state.workspace == nil ? "尚未载入工作区" : "未命名工作区"),
            entries: entries,
            generation: state.generation,
            dirty: state.isDirty,
            feedback: state.feedback,
            boundToFile: state.url != nil,
            busy: state.operation != nil
        )
        if let reveal {
            panel.reveal(reveal)
        }
    }

    /// 业务作用：一份候选定义全部通过后才更新面板，虚拟编辑不能留下部分树或修改原文件。
    /// 参数说明:
    /// - workspace: 完整有效的新定义。
    /// - index: 目标面板索引。
    /// - reveal: 需要显式定位的虚拟节点。
    /// 返回：定义身份改变，旧菜单和文件打开请求失权；磁盘保存点保持原状。
    func publishProject(_ workspace: ProjectWorkspace, in index: Int, reveal: UUID? = nil) {
        cancelProjectSearch(changing: index)
        let state = projectPanelStates[index]
        // 先撤销旧定义的打开资格，再发布完整新树，路径修改不能让旧读取落入新引用。
        cancelProjectOpen()
        state.generation = UUID()
        state.workspace = workspace
        state.feedback = "\(workspace.files.count) 个文件引用 · 可用性尚未检查"
        refreshProjectPanel(index, reveal: reveal)
    }

    /// 业务作用：退出前保护三个独立项目定义，正在进行的实际写入不得被当作已经保存。
    /// 参数说明: 无。
    /// 返回：没有未保存定义或用户明确放弃当前定义时为真，否则显示对应面板并取消退出。
    func permitsProjectTermination() -> Bool {
        // 项目写入的实际结果尚未返回时不能释放面板或把它记录成已经保存。
        if let index = projectPanelStates.firstIndex(where: {
            $0.operation != nil
        }) {
            showProjectPanel(index)
            let alert = NSAlert()
            alert.messageText = "项目工作区仍在处理"
            alert.informativeText = "请等待当前载入或保存完成，再退出 Nate。"
            alert.runModal()
            return false
        }
        let dirty = projectPanelStates.indices.filter {
            projectPanelStates[$0].isDirty
        }
        guard let first = dirty.first else {
            return true
        }
        let generations = projectPanelStates.map(\.generation)
        let alert = NSAlert()
        alert.messageText = "项目工作区有未保存的定义"
        alert.informativeText =
            "面板 \(dirty.map { String($0 + 1) }.joined(separator: "、")) 的项目结构或文件引用尚未写入工作区文件。可以返回项目面板保存，或明确放弃这些定义后退出。"
        alert.addButton(withTitle: "返回项目面板")
        alert.addButton(withTitle: "放弃定义后退出")
        let choice = alert.runModal()
        // 模态确认之后必须仍是同一批定义，不能用旧确认放弃刚发生的新编辑。
        guard choice == .alertSecondButtonReturn,
            generations == projectPanelStates.map(\.generation),
            projectPanelStates.allSatisfy({
                $0.operation == nil
            })
        else {
            showProjectPanel(first)
            return false
        }
        return true
    }
}
