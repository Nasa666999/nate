import AppKit
import NateCore

@MainActor
final class TabStrip: NSScrollView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAction: ((UUID, String) -> Void)?
    var onReorder: ((DocumentOrderMove) -> Bool)?
    let stack = TabCanvas()
    var layoutMode = DocumentTabLayout.horizontal
    var layoutPlan: DocumentTabLayoutPlan?
    var layingOutTabs = false
    var onRequiredHeight: ((CGFloat) -> Void)?
    var current: [TabPresentation] = []
    var displayLabels: [UUID: String] = [:]
    let dragOwner = UUID()
    var orderIdentity = UUID()
    var activeDrag: TabDragGesture?
    weak var dragSource: TabButton?
    var dragLocation = NSPoint.zero
    var dragTimer: Timer?
    var dragKeyMonitor: Any?
    let dropIndicator = NSView()

    /// 业务作用：建立可横向滚动的文档标签栏。
    /// 参数说明:
    /// - frameRect: 初始区域。
    /// 返回：拥有稳定文档身份的标签容器。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        documentView = stack
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.zPosition = 100
        dropIndicator.isHidden = true
        stack.addSubview(dropIndicator)
    }

    /// 业务作用：标签集合由工作区提供，不从系统归档另建身份。
    /// 参数说明:
    /// - coder: 归档读取器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：标签栏离开原窗口时立即撤销手势及周期任务，旧鼠标事件不能继续操作迁移后的视图。
    /// 参数说明:
    /// - newWindow: 即将接入的窗口，移出时为空。
    /// 返回：窗口身份改变前收回拖动资格并移除临时键盘监听。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let active = activeDrag {
            endTitleDrag(active.gesture)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// 业务作用：根据真实保存状态更新标签及其上下文动作。
    /// 参数说明:
    /// - tabs: 有序标签呈现。
    /// 返回：按相同顺序显示并绑定正确的文档。
    func update(_ tabs: [TabPresentation]) {
        guard current != tabs else {
            return
        }
        displayLabels = TabPresentation.labels(for: tabs)
        let selectedChanged =
            current.first(where: {
                $0.selected
            })?.id
            != tabs.first(where: {
                $0.selected
            })?.id
        let groups = stack.arrangedSubviews.compactMap {
            $0 as? NSStackView
        }
        if current.map(\.id) == tabs.map(\.id), groups.count == tabs.count {
            // 周期保存只更新标签状态，保留原标题实例，正在进行的合法移动不能被后台重绘撤销。
            current = tabs
            for (group, tab) in zip(groups, tabs) {
                updateGroup(group, tab: tab)
            }
            layoutTabs()
            if selectedChanged {
                revealSelectedTab()
            }
            return
        }
        if current.map(\.id) != tabs.map(\.id) {
            // 文档集合或原顺序已经改变，旧手势不能再按后来布局取得移动资格。
            if let active = activeDrag {
                endTitleDrag(active.gesture)
            }
            orderIdentity = UUID()
            dropIndicator.isHidden = true
        }
        current = tabs
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tab in tabs {
            let group = NSStackView()
            group.spacing = 2
            group.wantsLayer = true
            group.layer?.backgroundColor =
                (tab.selected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
            group.layer?.cornerRadius = 4
            group.edgeInsets = NSEdgeInsets(
                top: 3,
                left: 7,
                bottom: 3,
                right: 5
            )
            let button = TabButton(
                title: displayLabels[tab.id] ?? tab.statusPrefix + tab.title,
                target: self,
                action: #selector(selectTab(_:))
            )
            button.documentID = tab.id
            button.owner = self
            button.orderIdentity = orderIdentity
            button.onBeginDrag = {
                [weak self] source, event in
                self?.beginTitleDrag(source, event: event) ?? false
            }
            button.onAction = {
                [weak self] action in self?.onAction?(tab.id, action)
            }
            button.isBordered = false
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.font = NSFont.systemFont(ofSize: 12, weight: tab.selected ? .semibold : .regular)
            button.toolTip = tab.path ?? "未命名临时文档"
            group.addArrangedSubview(button)
            let close = TabButton(
                title: "×",
                target: self,
                action: #selector(closeTab(_:))
            )
            close.documentID = tab.id
            close.onAction = {
                [weak self] action in self?.onAction?(tab.id, action)
            }
            close.isBordered = false
            close.toolTip = "关闭此文档"
            group.addArrangedSubview(close)
            stack.addArrangedSubview(group)
        }
        layoutTabs()
        if selectedChanged {
            revealSelectedTab()
        }
    }

    /// 业务作用：正文和保存状态变化沿用原标签控件，真实手势仍按稳定文档身份持有来源。
    /// 参数说明:
    /// - group: 原顺序中现有的标签容器。
    /// - tab: 相同文档身份的最新呈现。
    /// 返回：只更新文字、颜色和路径提示，不改变标题实例、拖动代次或正文焦点。
    private func updateGroup(_ group: NSStackView, tab: TabPresentation) {
        guard let button = group.arrangedSubviews.first as? TabButton, button.documentID == tab.id else {
            return
        }
        group.layer?.backgroundColor =
            (tab.selected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        button.title = displayLabels[tab.id] ?? tab.statusPrefix + tab.title
        button.font = NSFont.systemFont(ofSize: 12, weight: tab.selected ? .semibold : .regular)
        button.toolTip = tab.path ?? "未命名临时文档"
    }

    /// 业务作用：点击标签只激活该标签绑定的文档。
    /// 参数说明:
    /// - sender: 被点击标签。
    /// 返回：发送稳定身份，不依赖当前活动标签。
    @objc func selectTab(_ sender: TabButton) {
        if let id = sender.documentID,
            current.contains(where: {
                $0.id == id
            })
        {
            onSelect?(id)
        }
    }

    /// 业务作用：关闭按钮明确指向对应标签。
    /// 参数说明:
    /// - sender: 被点击关闭按钮。
    /// 返回：交给工作区进行内容保护。
    @objc func closeTab(_ sender: TabButton) {
        if let id = sender.documentID,
            current.contains(where: {
                $0.id == id
            })
        {
            onClose?(id)
        }
    }
}
