import Foundation
import NateUI

extension ApplicationController {
    /// 业务作用：单窗口沿用原工作区顺序，创建独立窗口前固定原标签集合。
    /// 参数说明: 无。
    /// 返回：原窗口已登记一个独立顺序，其余文档仍由共享工作区协调。
    func beginWorkspaceTabGroups() {
        guard windowTabGroups.isEmpty, let mainWindow else {
            return
        }
        windowTabGroups[ObjectIdentifier(mainWindow)] = documents.map(\.buffer.id)
    }

    /// 业务作用：编辑和导航读取窗口自己的有序标签集合，文档对象仍在工作区唯一登记。
    /// 参数说明:
    /// - window: 需要读取标签的原窗口，为空时读取工作区的初始顺序。
    /// 返回：标签的原显示顺序，单窗口尚未分组时使用原工作区顺序。
    func workspaceTabIDs(in window: EditorWindow?) -> [UUID] {
        if let window, let group = windowTabGroups[ObjectIdentifier(window)] {
            return group
        }
        return documents.map(\.buffer.id)
    }

    /// 业务作用：按窗口自己的标签顺序找到仍存在的共享文档供命令使用。
    /// 参数说明:
    /// - window: 实际发出命令的窗口。
    /// 返回：工作区内实际存在的文档，顺序与原窗口一致。
    func workspaceTabDocuments(in window: EditorWindow?) -> [WorkspaceDocument] {
        guard let window, let group = windowTabGroups[ObjectIdentifier(window)] else {
            return documents
        }
        let lookup = Dictionary(uniqueKeysWithValues: documents.map { ($0.buffer.id, $0) })
        return group.compactMap { lookup[$0] }
    }

    /// 业务作用：将现有正文登记到指定窗口，打开同一文件时复用已有标签和原保存通道。
    /// 参数说明:
    /// - id: 已登记的文档身份。
    /// - window: 接受新标签的实际窗口。
    /// 返回：缺少该标签的窗口加入一个标签，未分组窗口沿用共享索引。
    func attachWorkspaceTab(_ id: UUID, to window: EditorWindow?) {
        guard let window else {
            return
        }
        let key = ObjectIdentifier(window)
        guard var group = windowTabGroups[key], !group.contains(id) else {
            return
        }
        group.append(id)
        windowTabGroups[key] = group
    }

    /// 业务作用：只关闭指定窗口的标签，其他窗口仍使用该文档时保留共享正文和文件任务。
    /// 参数说明:
    /// - id: 用户明确关闭的标签身份。
    /// - source: 发出关闭意图的编辑窗口。
    /// 返回：关闭一个克隆时只移除本窗口的标签，最后一次关闭则进入工作区文件保护流程。
    func closeWorkspaceTab(_ id: UUID, in source: EditorWindow) async {
        guard !closing, isWorkspaceWindowAvailable(source), workspaceTabIDs(in: source).contains(id) else {
            return
        }
        let anotherView = editorWindows.contains {
            $0 !== source && workspaceTabIDs(in: $0).contains(id)
        }
        if !anotherView {
            await closeDocument(id)
            return
        }
        let key = ObjectIdentifier(source)
        guard let group = windowTabGroups[key], source.finishCompositions(documentID: id) else {
            return
        }
        let remaining = group.filter { $0 != id }
        guard let next = remaining.first else {
            closeWorkspaceWindow(source)
            return
        }
        // 先确保替代标签能接管可见视图，再释放当前窗口中的共享克隆。
        source.retireDocument(id)
        if source.editor.document.id == id, !activate(next, in: source) {
            return
        }
        source.forgetTabViewPosition(id)
        windowTabGroups[key] = remaining
        if mainWindow === source {
            activeID = source.editor.document.id
        }
        refreshUI()
    }

    /// 业务作用：关闭窗口前把其独有标签交给另一窗口，仍在其它窗口使用的文档无需重复添加。
    /// 参数说明:
    /// - source: 即将关闭的窗口。
    /// - destination: 保留这些标签的现有窗口。
    /// - survivors: 关闭后仍可接受命令的窗口集合。
    /// 返回：移除原窗口的分组，回到单窗口时以实际顺序恢复工作区索引。
    func retireWorkspaceTabGroup(
        _ source: EditorWindow,
        preservingIn destination: EditorWindow,
        survivors: [EditorWindow]
    ) {
        let visible = Set(survivors.flatMap { workspaceTabIDs(in: $0) })
        for id in workspaceTabIDs(in: source) where !visible.contains(id) {
            destination.receiveTabViewPosition(id, from: source)
            attachWorkspaceTab(id, to: destination)
        }
        windowTabGroups.removeValue(forKey: ObjectIdentifier(source))
        if survivors.count == 1 {
            let ordered = workspaceTabDocuments(in: destination)
            if ordered.count == documents.count {
                // 全部共享文档都已保留，单窗口的实际顺序随后成为恢复顺序。
                documents = ordered
                windowTabGroups.removeAll()
            }
        }
    }
}
