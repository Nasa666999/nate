import AppKit
import NateCore

@MainActor
final class WorkspacePanelDock: NSObject, NSWindowDelegate, NSTabViewDelegate {
    let container = NSSplitView()
    private let center = NSSplitView()
    private let left = NSTabView()
    private let right = NSTabView()
    private let top = NSTabView()
    private let bottom = NSTabView()
    private lazy var groups: [WorkspacePanelPlacement: NSTabView] = [
        .left: left, .right: right, .top: top, .bottom: bottom,
    ]
    private var items: [WorkspacePanel: NSTabViewItem] = [:]
    private var placements: [WorkspacePanel: WorkspacePanelPlacement] = [:]
    private var shown: Set<WorkspacePanel> = []
    private var floatingWindows: [WorkspacePanel: NSPanel] = [:]
    private var floatingFrames: [WorkspacePanel: WindowSessionFrame] = [:]
    private var extents: [WorkspacePanelPlacement: CGFloat] = [:]
    private var pendingRestoredExtents: Set<WorkspacePanelPlacement> = []
    private var applyingRestoredExtents = false
    private weak var owner: EditorWindow?

    /// 业务作用：原面板内容由同一工作区控制层在分隔区域和浮动容器间移动。
    /// 参数说明:
    /// - owner: 持有当前正文和作出焦点决定的窗口。
    /// - editor: 实际正文分屏容器。
    /// - views: 此窗口拥有的全部实际工具面板。
    /// 返回：原生可调整布局已构建，默认隐藏工具区域。
    func connect(owner: EditorWindow, editor: NSSplitView, views: [WorkspacePanel: NSView]) {
        self.owner = owner
        for (panel, view) in views {
            let item = NSTabViewItem(identifier: panel.rawValue)
            item.label = panel.title
            item.view = view
            view.isHidden = true
            items[panel] = item
            placements[panel] = panel.defaultPlacement
        }
        for group in groups.values {
            group.isHidden = true
            group.tabViewType = .noTabsNoBorder
            group.delegate = self
        }
        center.isVertical = true
        center.dividerStyle = .thin
        center.addArrangedSubview(left)
        center.addArrangedSubview(editor)
        center.addArrangedSubview(right)
        container.isVertical = false
        container.dividerStyle = .thin
        container.addArrangedSubview(top)
        container.addArrangedSubview(center)
        container.addArrangedSubview(bottom)
        for index in [0, 2] {
            center.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: index)
            container.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: index)
        }
    }

    /// 业务作用：命令菜单读取实际面板所在位置，未连接窗口使用明确默认。
    /// 参数说明:
    /// - panel: 当前窗口内的面板身份。
    /// 返回：当前登记的停靠方向或浮动方式。
    func placement(of panel: WorkspacePanel) -> WorkspacePanelPlacement {
        placements[panel] ?? panel.defaultPlacement
    }

    /// 业务作用：显示时进入同一停靠组的此面板，隐藏只解除容器可见关系而保留内容。
    /// 参数说明:
    /// - panel: 用户操作的面板。
    /// - visible: 是否打开。
    /// - selecting: 是否切换到此面板所在的组合标签。
    /// 返回：现有面板更新显示状态，重复打开选中原组内标签。
    func setVisible(_ panel: WorkspacePanel, _ visible: Bool, selecting: Bool = true) {
        guard let item = items[panel] else {
            return
        }
        let position = placement(of: panel)
        if visible {
            if shown.insert(panel).inserted {
                item.view?.isHidden = false
                attach(panel, item: item, at: position, selecting: selecting)
            }
            else {
                if selecting {
                    groups[position]?.selectTabViewItem(item)
                }
                synchronizeFloatingVisibility()
            }
        }
        else if shown.remove(panel) != nil {
            detach(panel, item: item, from: position)
            item.view?.isHidden = true
        }
    }

    /// 业务作用：移动实际面板视图及其内容，已关闭的面板仅更新下次显示位置。
    /// 参数说明:
    /// - panel: 被移动的原面板。
    /// - position: 目标边或浮动。
    /// 返回：新容器接管已打开面板，原正文和工具数据保持原状态。
    func move(_ panel: WorkspacePanel, to position: WorkspacePanelPlacement) {
        let previous = placement(of: panel)
        guard previous != position, let item = items[panel] else {
            return
        }
        if shown.contains(panel) {
            // 先解除原生容器关系再移入，单个面板始终只由一个实际视图承载。
            detach(panel, item: item, from: previous)
        }
        placements[panel] = position
        if shown.contains(panel) {
            attach(panel, item: item, at: position)
        }
    }

    /// 业务作用：将同边面板组合成原生标签，或为独立浮动面板建立所属窗口。
    /// 参数说明:
    /// - panel: 已确认打开的面板。
    /// - item: 持有此面板原视图的稳定标签项。
    /// - position: 目标容器的停靠边或浮动方式。
    /// - selecting: 是否把这一面板选作停靠组正在展示的工具。
    /// 返回：面板进入可见目标，浮动窗口由原编辑窗口统一管理。
    private func attach(
        _ panel: WorkspacePanel,
        item: NSTabViewItem,
        at position: WorkspacePanelPlacement,
        selecting: Bool = true
    ) {
        if let group = groups[position] {
            let previous = group.selectedTabViewItem
            group.addTabViewItem(item)
            group.selectTabViewItem(selecting ? item : previous ?? item)
            updateGroup(at: position)
        }
        else if let view = item.view, let owner, let parent = owner.window {
            let previous = floatingFrames[panel]
            let initial =
                previous.map {
                    NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? NSRect(x: parent.frame.midX + 18, y: parent.frame.midY - 120, width: 420, height: 300)
            let window = NSPanel(
                contentRect: initial,
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            window.title = panel.title
            window.isFloatingPanel = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 220, height: 140)
            window.delegate = self
            window.contentView = view
            window.setFrame(owner.visibleRecoveryFrame(initial), display: false)
            floatingWindows[panel] = window
            synchronizeFloatingVisibility()
        }
    }

    /// 业务作用：收录布局位置后解除原容器关系，防止关闭或反复移动残留旧浮动窗口。
    /// 参数说明:
    /// - panel: 需要离开当前容器的面板。
    /// - item: 原面板的稳定视图项。
    /// - position: 当前实际容器。
    /// 返回：保留视图内容和上次尺寸，原容器已收回其展示资格。
    private func detach(_ panel: WorkspacePanel, item: NSTabViewItem, from position: WorkspacePanelPlacement)
    {
        if let group = groups[position] {
            if let extent = measuredExtent(at: position) {
                extents[position] = extent
            }
            group.removeTabViewItem(item)
            updateGroup(at: position)
        }
        else if let window = floatingWindows.removeValue(forKey: panel) {
            floatingFrames[panel] = sessionFrame(window.frame)
            window.parent?.removeChildWindow(window)
            window.delegate = nil
            window.contentView = nil
            window.close()
        }
    }

    /// 业务作用：只有实际使用的停靠组占用区域，两个及以上的工具显示可切换的原生标签。
    /// 参数说明:
    /// - position: 需要重算的停靠边。
    /// 返回：组可见性与原生排版同步，首次展开使用已记忆或适合当前窗口的尺寸。
    private func updateGroup(at position: WorkspacePanelPlacement) {
        guard let group = groups[position] else {
            return
        }
        let wasHidden = group.isHidden
        group.isHidden = group.numberOfTabViewItems == 0
        group.tabViewType = group.numberOfTabViewItems > 1 ? .topTabsBezelBorder : .noTabsNoBorder
        owner?.window?.contentView?.layoutSubtreeIfNeeded()
        container.adjustSubviews()
        center.adjustSubviews()
        if wasHidden && !group.isHidden {
            applyExtent(at: position)
        }
    }

    /// 业务作用：从原生分隔区域读取当前尺寸，仅在对应边实际可见时生成范围。
    /// 参数说明:
    /// - position: 当前停靠边。
    /// 返回：宽度或高度，隐藏、浮动或尚未形成几何时为空。
    private func measuredExtent(at position: WorkspacePanelPlacement) -> CGFloat? {
        guard let group = groups[position], !group.isHidden else {
            return nil
        }
        let value = position == .left || position == .right ? group.frame.width : group.frame.height
        return value > 1 && value.isFinite ? value : nil
    }

    /// 业务作用：按真实窗口空间还原用户上次调整的分隔位置，并给正文保留可操作范围。
    /// 参数说明:
    /// - position: 已可见的停靠边。
    /// 返回：当前窗口尺寸可用时调整实际分隔线，尚未形成布局时由后续窗口显示处理。
    private func applyExtent(at position: WorkspacePanelPlacement) {
        guard groups[position]?.isHidden == false else {
            return
        }
        let horizontal = position == .left || position == .right
        let area = horizontal ? center : container
        let total = horizontal ? area.bounds.width : area.bounds.height
        guard total >= 150 else {
            return
        }
        let preferred = extents[position] ?? (horizontal ? 260 : 200)
        let opposite: WorkspacePanelPlacement =
            horizontal ? (position == .left ? .right : .left) : (position == .top ? .bottom : .top)
        let remainder = total - (measuredExtent(at: opposite) ?? 0) - 100
        let extent = max(40, min(preferred, max(40, remainder), total * 0.48))
        let first = position == .left || position == .top
        let divider = first ? 0 : 1
        let point = first ? extent : total - extent - area.dividerThickness
        area.setPosition(point, ofDividerAt: divider)
        area.layoutSubtreeIfNeeded()
        if let observed = measuredExtent(at: position), abs(extent - observed) > 0.5 {
            // 原生容器会因子视图尺寸或分隔线留白调整位置，按实际边宽补偿而不是重复使用旧坐标。
            let delta = extent - observed
            area.setPosition(point + (first ? delta : -delta), ofDividerAt: divider)
        }
    }

    /// 业务作用：浮动面板随所属编辑窗口的可见状态交接或隐藏，后台布局读取不会擅自激活窗口。
    /// 参数说明: 无。
    /// 返回：所有当前浮动面板拥有正确的原生父窗口与可见性。
    func synchronizeFloatingVisibility() {
        guard let parent = owner?.window else {
            return
        }
        applyInitialDockSizes()
        for panel in floatingWindows.values {
            if parent.isVisible && !parent.isMiniaturized {
                if panel.parent !== parent || !panel.isVisible {
                    if panel.parent !== parent {
                        parent.addChildWindow(panel, ordered: .above)
                    }
                    panel.orderFront(nil)
                }
            }
            else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    /// 业务作用：编辑窗口离开后释放所有独立浮动容器，原窗口不会被面板事件继续持有。
    /// 参数说明: 无。
    /// 返回：浮动面板不再参与事件路由，资源由窗口生命周期收回。
    func closeFloatingWindows() {
        for panel in Array(floatingWindows.keys) {
            if let item = items[panel] {
                detach(panel, item: item, from: .floating)
            }
        }
    }

    /// 业务作用：只让此窗口拥有的浮动工具参与编辑焦点交接。
    /// 参数说明:
    /// - native: 当前原生键盘窗口。
    /// 返回：属于此工作区的实际浮动面板时为真。
    func ownsFloatingWindow(_ native: NSWindow?) -> Bool {
        floatingWindows.values.contains { $0 === native }
    }

    /// 业务作用：窗口恢复读取实际停靠标签、可见状态和浮动位置，而不是猜测面板是否有数据。
    /// 参数说明: 无。
    /// 返回：当前窗口全部工作区工具的独立布局。
    func session() -> [WorkspacePanelSession] {
        WorkspacePanel.allCases.map {
            panel in
            let position = placement(of: panel)
            return WorkspacePanelSession(
                panel: panel,
                placement: position,
                visible: shown.contains(panel),
                selected: groups[position]?.selectedTabViewItem === items[panel] && shown.contains(panel),
                floatingFrame: floatingWindows[panel].map { sessionFrame($0.frame) } ?? floatingFrames[panel],
                extent: (measuredExtent(at: position) ?? extents[position]).map { Double($0) }
            )
        }
    }

    /// 业务作用：启动时依照已验证的布局重新组装面板，工具内容继续经由各自入口恢复。
    /// 参数说明:
    /// - states: 原窗口的完整停靠、组合与浮动记录。
    /// 返回：可见组及活动标签应用原状态，浮动面板等待编辑窗口显示。
    func restore(_ states: [WorkspacePanelSession]) {
        for state in states {
            floatingFrames[state.panel] = state.floatingFrame
            if let extent = state.extent {
                extents[state.placement] = extent
                if state.visible && state.placement != .floating {
                    pendingRestoredExtents.insert(state.placement)
                }
            }
            move(state.panel, to: state.placement)
            setVisible(state.panel, state.visible)
        }
        for state in states where state.selected {
            if let item = items[state.panel] {
                groups[state.placement]?.selectTabViewItem(item)
            }
        }
        for position in groups.keys {
            applyExtent(at: position)
        }
    }

    /// 业务作用：首次显示后用已完成的原生布局确认停靠尺寸，同时保留正文的逻辑顶行。
    /// 参数说明: 无。
    /// 返回：恢复尺寸应用一次，后续手动拖动保留其独立结果。
    private func applyInitialDockSizes() {
        guard !pendingRestoredExtents.isEmpty, !applyingRestoredExtents,
            owner?.window?.isVisible == true
        else {
            return
        }
        applyingRestoredExtents = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            applyingRestoredExtents = false
            guard let owner, owner.window?.isVisible == true else {
                return
            }
            let restored = pendingRestoredExtents
            pendingRestoredExtents.removeAll()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let viewports = owner.editorSplit.arrangedSubviews.compactMap {
                view -> (EditorView, EditorViewportAnchor?)? in
                guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                    return nil
                }
                return (editor, editor.viewportAnchor())
            }
            for position in restored {
                applyExtent(at: position)
            }
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            owner.refreshEditors()
            for (editor, viewport) in viewports {
                editor.restoreViewportAnchor(viewport)
            }
        }
    }

    /// 业务作用：浮动窗口关闭只隐藏所属工具，结果区仍执行原输入草稿的保护。
    /// 参数说明:
    /// - sender: 申请关闭的原生浮动窗口。
    /// 返回：工具通过工作区处理关闭，系统不擅自销毁面板视图。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let panel = floatingWindows.first(where: { $0.value === sender })?.key {
            owner?.setWorkspacePanelVisible(panel, false)
        }
        return false
    }

    /// 业务作用：浮动面板的实际键盘焦点仍由所属编辑窗口负责命令范围。
    /// 参数说明:
    /// - notification: 浮动面板取得焦点的系统通知。
    /// 返回：只有仍属于此窗口的浮动面板可以报告自己的工作区。
    func windowDidBecomeKey(_ notification: Notification) {
        if let sender = notification.object as? NSWindow,
            floatingWindows.values.contains(where: { $0 === sender })
        {
            owner?.onWorkspaceFocus?()
        }
    }

    /// 业务作用：同一停靠组切换时为尚未确认的结果筛选保留原生输入上下文。
    /// 参数说明:
    /// - tabView: 用户操作的实际工具组。
    /// - tabViewItem: 请求切换的工具标签。
    /// 返回：离开结果前筛选已收束时允许切换，否则保留原标签和候选。
    func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        guard let results = items[.results], tabView.selectedTabViewItem === results, tabViewItem !== results,
            owner?.searchResults.isEditingInput == true
        else {
            return true
        }
        owner?.status.stringValue = "请先确认或取消结果筛选输入，再切换停靠标签。"
        return false
    }

    /// 业务作用：地图加入原生工具组后，只在其所在组发生切换时复验可见来源。
    /// 参数说明:
    /// - tabView: 实际切换的工具组。
    /// - tabViewItem: AppKit 已选中的工具标签。
    /// 返回：地图随选中的原生标签显示或释放旧正文投影。
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let owner, let map = items[.documentMap], tabView.tabViewItems.contains(where: { $0 === map }) {
            owner.documentMap.update(for: owner.editor)
        }
    }

    /// 业务作用：把原生框架坐标转为独立持久化数据。
    /// 参数说明:
    /// - frame: 浮动面板的实际屏幕区域。
    /// 返回：不依赖原生视图对象的完整布局几何。
    private func sessionFrame(_ frame: NSRect) -> WindowSessionFrame {
        WindowSessionFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
}
