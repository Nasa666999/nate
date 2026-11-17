import AppKit
import NateCore
import NateStorage

extension ApplicationController {
    /// 业务作用：用户明确选择目录后把本次文件清单加入虚拟分组，后续目录变化仍由独立目录工作区负责。
    /// 参数说明:
    /// - index: 当前独立面板。
    /// - parent: 接收新增引用的有效项目或虚拟分组。
    /// - operation: 当前动作身份。
    /// - explicitRoot: 已由调用方明确选择的目录，为空时显示系统选择界面。
    /// 返回：完整有界目录清单与虚拟结构全部有效才加入，失败或取消保留原定义。
    func addProjectDirectory(
        _ index: Int,
        parent: UUID,
        operation: UUID,
        explicitRoot: URL? = nil
    ) async throws {
        let root: URL
        if let explicitRoot {
            root = explicitRoot
        }
        else {
            let panel = NSOpenPanel()
            panel.title = "将目录清单加入虚拟项目"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let selected = panel.url else {
                return
            }
            root = selected
        }
        // 目录选择不改变原面板动作身份，嵌套事件循环后必须重新确认其有效性。
        guard projectOperationCurrent(index, operation: operation),
            let original = projectPanelStates[index].workspace
        else {
            return
        }
        let (workspace, first, paths) = try await readIO.readCancellable {
            token in
            try token.check()
            var additions: [ProjectNode] = []
            var paths: [Data] = []
            var remaining = 4 * 1024 * 1024
            for node in original.nodes {
                remaining -= node.name.utf8.count + (node.path?.utf8.count ?? 0)
            }
            /// 业务作用：目录导入过程中提前限制虚拟节点与原文容量，不能先建立超量引用后再截断。
            /// 参数说明:
            /// - node: 本次准备加入的完整节点。
            /// 返回：容量足够才记录节点，超限明确失败且不发布任何部分定义。
            func append(_ node: ProjectNode) throws {
                let size = node.name.utf8.count + (node.path?.utf8.count ?? 0)
                guard original.nodes.count + additions.count < 20_000, size <= remaining else {
                    throw NateError.message("目录清单使项目超过 20000 节点或 4 MiB 原文，未加入部分引用。")
                }
                remaining -= size
                additions.append(node)
            }
            let rootName = root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent
            let group = ProjectNode(
                parent: parent,
                kind: .folder,
                name: rootName.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(
                    of: "\r",
                    with: "\\r"
                )
            )
            try append(group)
            var pending: [(URL, UUID)] = [(root, group.id)]
            while let (directory, owner) = pending.popLast() {
                try token.check()
                // 每一层沿原根目录描述符取得读取资格，符号链接、隐藏项和应用包不会进入导入后代。
                let contents = try DirectoryContents.read(
                    root: root,
                    directory: directory,
                    limit: 20_000,
                    permit: {
                        !token.isCancelled
                    }
                )
                for entry in contents.entries {
                    try token.check()
                    let name = entry.url.lastPathComponent
                    let node = ProjectNode(
                        parent: owner,
                        kind: entry.isDirectory ? .folder : .file,
                        name: entry.isDirectory
                            ? name.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(
                                of: "\r",
                                with: "\\r"
                            )
                            : name,
                        path: entry.isDirectory ? nil : entry.url.path
                    )
                    try append(node)
                    if entry.isDirectory {
                        pending.append((entry.url, node.id))
                    }
                    else {
                        paths.append(Data(entry.url.standardizedFileURL.path.utf8))
                    }
                }
            }
            var workspace = original
            try workspace.insert(additions)
            try token.check()
            return (workspace, group.id, paths)
        }
        // 后台导入不能覆盖动作期间被替换的定义或退出时已经冻结的面板。
        guard projectOperationCurrent(index, operation: operation) else {
            return
        }
        projectPanelStates[index].selectedPaths.formUnion(paths)
        publishProject(workspace, in: index, reveal: first)
    }
}
