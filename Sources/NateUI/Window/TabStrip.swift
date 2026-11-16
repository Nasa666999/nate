import AppKit

@MainActor
final class TabStrip: NSScrollView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAction: ((UUID, String) -> Void)?
    let stack = NSStackView()
    var current: [TabPresentation] = []

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
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        documentView = stack
    }

    /// 业务作用：标签集合由工作区提供，不从系统归档另建身份。
    /// 参数说明:
    /// - coder: 归档读取器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：根据真实保存状态更新标签及其上下文动作。
    /// 参数说明:
    /// - tabs: 有序标签呈现。
    /// 返回：按相同顺序显示并绑定正确的文档。
    func update(_ tabs: [TabPresentation]) {
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
            group.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 5)
            let prefix = tab.failed ? "⚠ " : tab.pinned ? "◆ " : tab.dirty ? "● " : ""
            let button = TabButton(title: prefix + tab.title, target: self, action: #selector(selectTab(_:)))
            button.documentID = tab.id
            button.onAction = {
                [weak self] action in self?.onAction?(tab.id, action)
            }
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: tab.selected ? .semibold : .regular)
            button.toolTip = tab.path ?? "未命名临时文档"
            group.addArrangedSubview(button)
            let close = TabButton(title: "×", target: self, action: #selector(closeTab(_:)))
            close.documentID = tab.id
            close.isBordered = false
            close.toolTip = "关闭此文档"
            group.addArrangedSubview(close)
            stack.addArrangedSubview(group)
        }
        stack.frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: 32)
    }

    /// 业务作用：点击标签只激活该标签绑定的文档。
    /// 参数说明:
    /// - sender: 被点击标签。
    /// 返回：发送稳定身份，不依赖当前活动标签。
    @objc func selectTab(_ sender: TabButton) {
        if let id = sender.documentID {
            onSelect?(id)
        }
    }

    /// 业务作用：关闭按钮明确指向对应标签。
    /// 参数说明:
    /// - sender: 被点击关闭按钮。
    /// 返回：交给工作区进行内容保护。
    @objc func closeTab(_ sender: TabButton) {
        if let id = sender.documentID {
            onClose?(id)
        }
    }
}

@MainActor
final class TabButton: NSButton {
    var documentID: UUID?
    var onAction: ((String) -> Void)?

    /// 业务作用：上下文菜单动作始终绑定右键实际指向的标签。
    /// 参数说明:
    /// - event: 当前右键事件。
    /// 返回：适用于被点击文档的操作列表。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, id) in [
            ("关闭", "close"), ("关闭其他", "closeOthers"), ("关闭左侧", "closeLeft"),
            ("关闭右侧", "closeRight"), ("固定 / 取消固定", "pin"), ("复制完整路径", "copyPath"),
            ("在 Finder 显示", "reveal"), ("克隆到分屏", "clone"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        return menu
    }

    /// 业务作用：将上下文动作连同原标签身份交给工作区。
    /// 参数说明:
    /// - sender: 菜单项。
    /// 返回：只发送对应动作，不改变当前活动标签。
    @objc func contextAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onAction?(id)
        }
    }
}
