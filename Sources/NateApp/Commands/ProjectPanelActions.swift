import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：为一个项目面板登记唯一当前动作，独立面板之间不转移定义或保存结果。
    /// 参数说明:
    /// - action: 原生项目菜单动作。
    /// - index: 当前可见独立面板索引。
    /// - node: 菜单已固定的虚拟节点身份。
    /// 返回：合法动作进入可收束任务，忙碌、隐藏或退出期间不建立新的编辑和写入权。
    func routeProjectAction(_ action: String, panel index: Int, node: UUID?) {
        // 不可见面板的旧菜单没有当前编辑权，同一面板的实际 I/O 未结束前也不能换一份定义。
        guard !closing, projectPanelStates.indices.contains(index),
            mainWindow?.projectPanels.isHidden == false,
            mainWindow?.projectPanels.selectedIndex == index,
            projectPanelStates[index].operation == nil
        else {
            return
        }
        let state = projectPanelStates[index]
        let operation = UUID()
        // 新的虚拟编辑或定义 I/O 接管当前面板意图，等待中的旧文件打开不得抢回焦点。
        directoryWorkspace?.cancelOpen()
        cancelProjectOpen()
        state.operation = operation
        refreshProjectPanel(index)
        state.task = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if state.operation == operation {
                    state.operation = nil
                    state.task = nil
                    if !self.closing {
                        self.refreshProjectPanel(index)
                    }
                }
            }
            do {
                try await self.performProjectAction(action, panel: index, node: node, operation: operation)
            }
            catch {
                // 失败反馈仍须属于原动作，迟到失败不能覆盖已换入工作区的状态。
                if self.projectOperationCurrent(index, operation: operation) {
                    state.feedback = error.localizedDescription + (state.saveBlocked ? " · 请重新载入或另存为。" : "")
                }
            }
        }
    }

    /// 业务作用：统一执行项目定义编辑与显式载入保存，全部虚拟修改先验证完整候选再发布。
    /// 参数说明:
    /// - action: 已获准的项目动作。
    /// - index: 目标面板。
    /// - node: 原菜单的稳定虚拟身份。
    /// - operation: 当前动作身份。
    /// 返回：完整当前定义或实际取消、失败反馈，文件引用内容不随虚拟编辑改变。
    func performProjectAction(_ action: String, panel index: Int, node: UUID?, operation: UUID) async throws {
        guard projectOperationCurrent(index, operation: operation) else {
            return
        }
        let state = projectPanelStates[index]
        switch action {
        case "new", "unload", "load", "reload":
            guard try await confirmProjectReplacement(index, operation: operation) else {
                return
            }
            if action == "new" || action == "unload" {
                cancelProjectOpen()
                state.generation = UUID()
                state.workspace = action == "new" ? ProjectWorkspace() : nil
                state.saved = state.workspace
                state.url = nil
                state.baseline = nil
                state.saveBlocked = false
                state.selectedPaths.removeAll()
                state.feedback = action == "new" ? "空工作区，可添加项目。" : "工作区已关闭，引用文件保留。"
            }
            else {
                let url: URL
                if action == "reload", let bound = state.url {
                    url = bound
                }
                else {
                    let panel = NSOpenPanel()
                    panel.title = "载入项目工作区"
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let selected = panel.url else {
                        state.feedback = "已取消载入，原项目定义保留。"
                        return
                    }
                    url = selected
                }
                guard projectOperationCurrent(index, operation: operation) else {
                    return
                }
                try await loadProjectDefinition(index, from: url, operation: operation)
            }
            return
        case "save", "saveAs":
            _ = try await saveProjectDefinition(index, operation: operation, forceSaveAs: action == "saveAs")
            return
        default:
            break
        }
        guard var workspace = state.workspace else {
            throw NateError.message("请先新建或载入此面板的工作区。")
        }
        switch action {
        case "addProject", "addFolder":
            let parent: UUID?
            if action == "addProject" {
                parent = nil
            }
            else {
                guard let node,
                    let owner = workspace.nodes.first(where: {
                        $0.id == node
                    }), owner.kind != .file
                else {
                    throw NateError.message("请先选择项目或虚拟分组。")
                }
                parent = node
            }
            guard
                let name = projectNamePrompt(
                    title: action == "addProject" ? "添加项目" : "添加虚拟分组",
                    value: action == "addProject" ? "新项目" : "新分组"
                ), projectOperationCurrent(index, operation: operation)
            else {
                return
            }
            let added = ProjectNode(
                parent: parent,
                kind: action == "addProject" ? .project : .folder,
                name: name
            )
            try workspace.insert([added])
            publishProject(workspace, in: index, reveal: added.id)
        case "rename", "changePath":
            guard let node,
                let current = workspace.nodes.first(where: {
                    $0.id == node
                })
            else {
                throw NateError.message("原项目节点已不存在。")
            }
            if action == "rename" {
                guard let name = projectNamePrompt(title: "修改虚拟显示名称", value: current.name),
                    projectOperationCurrent(index, operation: operation)
                else {
                    return
                }
                try workspace.rename(node, to: name)
            }
            else {
                guard current.kind == .file else {
                    throw NateError.message("当前虚拟节点没有文件路径。")
                }
                let chooser = NSOpenPanel()
                chooser.title = "选择项目文件引用的新位置"
                chooser.canChooseDirectories = false
                chooser.allowsMultipleSelection = false
                guard chooser.runModal() == .OK, let url = chooser.url,
                    projectOperationCurrent(index, operation: operation)
                else {
                    return
                }
                try FileStorage.validateFileURL(url)
                try workspace.changeReference(node, to: url.path)
                state.selectedPaths.insert(Data(url.standardizedFileURL.path.utf8))
            }
            publishProject(workspace, in: index, reveal: node)
        case "addFiles":
            guard let node,
                workspace.nodes.contains(where: {
                    $0.id == node && $0.kind != .file
                })
            else {
                throw NateError.message("请先选择项目或虚拟分组。")
            }
            let urls = SystemIntegration.chooseFiles()
            guard !urls.isEmpty, projectOperationCurrent(index, operation: operation) else {
                return
            }
            guard urls.count <= 20_000 - workspace.nodes.count else {
                throw NateError.message("选择的文件使项目超过 20000 节点，未加入部分引用。")
            }
            let additions = try urls.map {
                url in
                try FileStorage.validateFileURL(url)
                return ProjectNode(
                    parent: node,
                    kind: .file,
                    name: url.lastPathComponent,
                    path: url.path
                )
            }
            try workspace.insert(additions)
            for url in urls {
                state.selectedPaths.insert(Data(url.standardizedFileURL.path.utf8))
            }
            publishProject(workspace, in: index, reveal: additions.last?.id)
        case "addDirectory":
            guard let node,
                workspace.nodes.contains(where: {
                    $0.id == node && $0.kind != .file
                })
            else {
                throw NateError.message("请先选择项目或虚拟分组。")
            }
            try await addProjectDirectory(index, parent: node, operation: operation)
        case "moveUp", "moveDown":
            guard let node else {
                return
            }
            if try workspace.moveSibling(node, offset: action == "moveUp" ? -1 : 1) {
                publishProject(workspace, in: index, reveal: node)
            }
        case "remove":
            guard let node,
                let current = workspace.nodes.first(where: {
                    $0.id == node
                })
            else {
                throw NateError.message("原项目节点已不存在。")
            }
            let alert = NSAlert()
            alert.messageText = "移除虚拟节点“\(current.name)”？"
            alert.informativeText = "该节点和后代引用将移出此定义，磁盘文件与已打开正文保持原状。"
            alert.addButton(withTitle: "移除")
            alert.addButton(withTitle: "取消")
            // 删除确认只允许作用于仍由当前动作持有的原定义。
            guard alert.runModal() == .alertFirstButtonReturn,
                projectOperationCurrent(index, operation: operation)
            else {
                return
            }
            try workspace.remove(node)
            publishProject(workspace, in: index)
        default:
            throw NateError.message("项目动作无法识别。")
        }
    }

    /// 业务作用：取得虚拟名称的完整已确认输入，不通过字段截断掩盖定义容量校验。
    /// 参数说明:
    /// - title: 当前虚拟动作说明。
    /// - value: 当前或建议显示名称。
    /// 返回：用户确认的完整名称，取消为空；名称合法性仍由完整定义验证。
    func projectNamePrompt(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let input = NSTextField(string: value)
        input.frame = NSRect(
            x: 0,
            y: 0,
            width: 360,
            height: 28
        )
        input.setAccessibilityLabel("虚拟节点显示名称")
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
}
