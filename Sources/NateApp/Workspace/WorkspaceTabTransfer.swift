import AppKit
import NatePlatform
import NateUI

extension ApplicationController {
    /// 业务作用：原生标签动作捕获其所属窗口，拖放和普通标签命令共用实际窗口来源。
    /// 参数说明:
    /// - window: 即将加入工作区的原生窗口。
    /// 返回：只连接该窗口拥有的标签动作，异步回调不借其他窗口获得发布权。
    func connectWorkspaceTabs(_ window: EditorWindow) {
        window.onSelect = {
            [weak self, weak window] id in
            guard let window else {
                return
            }
            self?.activate(id, in: window)
        }
        window.onCloseTab = {
            [weak self, weak window] id in
            Task {
                guard let self, let window, self.isWorkspaceWindowAvailable(window) else {
                    return
                }
                await self.closeWorkspaceTab(id, in: window)
            }
        }
        window.onTabAction = {
            [weak self, weak window] id, action in
            guard let self, self.mainWindow === window else {
                return
            }
            self.tabAction(id, action)
        }
        window.onTabReorder = {
            [weak self, weak window] move in
            guard let self, self.mainWindow === window else {
                return false
            }
            return self.reorderTabs(move)
        }
        window.onTabDropTarget = {
            [weak self, weak window] point in
            guard let self, let window else {
                return nil
            }
            return self.workspaceTabDropTarget(at: point, from: window)
        }
        window.onTabTransfer = {
            [weak self, weak window] transfer, destination in
            guard let self, let window else {
                return false
            }
            return self.transferWorkspaceTab(transfer, from: window, to: destination)
        }
    }

    /// 业务作用：在两扇窗口之间移动实际标签，保留唯一正文、保存通道、固定状态和独立视图位置。
    /// 参数说明:
    /// - transfer: 原文档身份、两侧顺序来源和目标插入位置。
    /// - source: 实际持有该标签的窗口。
    /// - destination: 接收标签的另一现有窗口。
    /// 返回：两侧原顺序与组合输入仍允许移动时为真，失效时保留原标签归属。
    @discardableResult
    func transferWorkspaceTab(
        _ transfer: WindowTabTransfer,
        from source: EditorWindow,
        to destination: EditorWindow
    ) -> Bool {
        let id = transfer.documentID
        let sourceKey = ObjectIdentifier(source)
        let destinationKey = ObjectIdentifier(destination)
        // 先复验两侧原顺序再确认候选，不能由关闭窗口或旧手势提交不相关的输入。
        guard !closing, source !== destination, isWorkspaceWindowAvailable(source),
            isWorkspaceWindowAvailable(destination), source.tabOrderIdentity == transfer.sourceGeneration,
            destination.tabOrderIdentity == transfer.destinationGeneration,
            let sourceOrder = windowTabGroups[sourceKey], sourceOrder.contains(id),
            var newDestinationOrder = windowTabGroups[destinationKey],
            transfer.before.map({ newDestinationOrder.contains($0) }) != false,
            let document = documents.first(where: { $0.buffer.id == id && !$0.closing }),
            source.finishCompositions(documentID: id), destination.editor.finishComposition()
        else {
            return false
        }
        let newSourceOrder = sourceOrder.filter { $0 != id }
        let sourceWasFocused = mainWindow === source && source.editor.document.id == id
        if !newDestinationOrder.contains(id) {
            destination.receiveTabViewPosition(id, from: source)
            let insertion = transfer.before.flatMap { newDestinationOrder.firstIndex(of: $0) }
            newDestinationOrder.insert(id, at: insertion ?? newDestinationOrder.count)
        }
        // 先建立目标视图再释放原标签。已经存在的目标克隆保留自己的位置和顺序。
        guard activate(document.buffer.id, in: destination) else {
            return false
        }
        if let next = newSourceOrder.first {
            source.retireDocument(id)
            if source.editor.document.id == id, !activate(next, in: source) {
                // 原视图无法接管替代正文时保留原标签，目标已建立的共享视图仍可使用。
                return false
            }
            source.forgetTabViewPosition(id)
        }
        windowTabGroups[sourceKey] = newSourceOrder
        windowTabGroups[destinationKey] = newDestinationOrder
        if sourceWasFocused || newSourceOrder.isEmpty && mainWindow === source {
            selectWorkspaceWindow(destination)
            destination.window?.makeKeyAndOrderFront(nil)
        }
        if newSourceOrder.isEmpty {
            closeWorkspaceWindow(source)
        }
        refreshUI()
        return true
    }

    /// 业务作用：标签窗口选择器从真实现有窗口取目标，弹窗期间变化会使旧选择失效。
    /// 参数说明:
    /// - id: 用户明确选中的标签身份。
    /// 返回：明确确认后尝试提交一次跨窗口移动，关闭确认或原顺序已改变时保持标签。
    func chooseWorkspaceTabDestination(_ id: UUID) {
        guard !closing, let source = mainWindow, workspaceTabIDs(in: source).contains(id) else {
            return
        }
        let sourceGeneration = source.tabOrderIdentity
        let destinations = editorWindows.filter { $0 !== source }.map {
            (window: $0, generation: $0.tabOrderIdentity)
        }
        guard !destinations.isEmpty else {
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        for (index, item) in destinations.enumerated() {
            let title = item.window.window?.title ?? "Nate"
            popup.addItem(withTitle: "\(index + 1). \(title)")
        }
        popup.setAccessibilityLabel("标签目标窗口")
        let alert = NSAlert()
        alert.messageText = "移动标签到另一窗口"
        alert.informativeText = "选择接收此文档的窗口。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
            destinations.indices.contains(popup.indexOfSelectedItem)
        else {
            return
        }
        let target = destinations[popup.indexOfSelectedItem]
        let transfer = WindowTabTransfer(
            documentID: id,
            sourceGeneration: sourceGeneration,
            destinationGeneration: target.generation,
            before: nil
        )
        if !transferWorkspaceTab(transfer, from: source, to: target.window) {
            source.status.stringValue = "窗口、标签顺序或输入状态已改变，请重新选择。"
        }
    }

    /// 业务作用：跨窗鼠标只交给屏幕落点上最前面的真实编辑窗口。
    /// 参数说明:
    /// - point: 原拖动事件转换后的屏幕坐标。
    /// - source: 保有原拖动的编辑窗口。
    /// 返回：目标真实标签栏可见时返回其窗口；面板遮挡、栏外和失效来源均为空。
    func workspaceTabDropTarget(at point: NSPoint, from source: EditorWindow) -> EditorWindow? {
        guard !closing, isWorkspaceWindowAvailable(source) else {
            return nil
        }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return editorWindows.first {
            $0 !== source && $0.window?.windowNumber == number && $0.acceptsTabDrop(at: point)
        }
    }

    /// 业务作用：标签上下文动作明确使用被点击身份，不能误操作活动文档。
    /// 参数说明:
    /// - id: 被点击文档。
    /// - action: 上下文命令。
    /// 返回：按该文档执行动作。
    func tabAction(_ id: UUID, _ action: String) {
        // 退出期间允许任务观察，但标签动作不能另建关闭流程或修改已经固定的恢复元数据。
        guard !closing, workspaceTabIDs(in: mainWindow).contains(id) else {
            return
        }
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        switch action {
        case "moveTabLeft", "moveTabRight", "moveTabFirst", "moveTabLast":
            moveTab(id, action: action)
        case "moveTabToWindow":
            chooseWorkspaceTabDestination(id)
        case "close":
            if let window = mainWindow {
                Task {
                    await closeWorkspaceTab(id, in: window)
                }
            }
        case "pin":
            document.pinned.toggle()
            refreshUI()
        case "copyPath":
            if let path = document.url?.path {
                SystemIntegration.copy(path)
            }
        case "reveal":
            if let url = document.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case "clone":
            activate(id)
            mainWindow?.splitEditor(vertical: true)
        default: closeGroup(action, reference: id)
        }
    }
}
