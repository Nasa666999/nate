import AppKit

@MainActor
final class TabButton: NSButton {
    var documentID: UUID?
    var onAction: ((String) -> Void)?
    var onBeginDrag: ((TabButton, NSEvent) -> Bool)?
    weak var owner: TabStrip?
    var orderIdentity: UUID?
    private var pressedEvent: NSEvent?
    private var dragStarted = false
    private var dragGesture: UUID?

    /// 业务作用：普通点击激活稳定标签，越过阈值后改为原生拖动，不把拖放同时解释为切换文档。
    /// 参数说明:
    /// - event: 当前真实鼠标按下事件。
    /// 返回：点击只执行一次；窗口失效、鼠标释放在外部或旧手势被撤销时不产生标签动作。
    override func mouseDown(with event: NSEvent) {
        guard onBeginDrag != nil, !event.modifierFlags.contains(.control), window != nil else {
            super.mouseDown(with: event)
            return
        }
        if let gesture = dragGesture {
            owner?.endTitleDrag(gesture)
        }
        dragGesture = nil
        pressedEvent = event
        dragStarted = false
    }

    /// 业务作用：跨过阈值后开始原生拖动，独立事件分发使保存与其它主线程任务继续调度。
    /// 参数说明:
    /// - event: 实际原生拖动事件。
    /// 返回：一个按下序列最多启动一次会话；旧窗口或已移除按钮不产生动作。
    override func mouseDragged(with event: NSEvent) {
        if dragStarted {
            owner?.updateTitleDrag(self, gesture: dragGesture, event: event)
            return
        }
        guard let pressed = pressedEvent, let native = window,
            native.isVisible, pressed.windowNumber == native.windowNumber,
            let point = owner?.titleDragLocation(event)
        else {
            return
        }
        let start = pressed.locationInWindow
        if hypot(point.x - start.x, point.y - start.y) >= 4 {
            dragStarted = true
            if onBeginDrag?(self, pressed) == true {
                dragGesture = owner?.activeDrag?.gesture
                owner?.updateTitleDrag(self, gesture: dragGesture, event: event)
            }
        }
    }

    /// 业务作用：没有开始拖动的合法释放才激活标签，取消或拖动不会补发一次点击。
    /// 参数说明:
    /// - event: 原生鼠标释放事件。
    /// 返回：合法栏内点击最多执行一次，序列的临时状态始终收回。
    override func mouseUp(with event: NSEvent) {
        let pressed = pressedEvent
        pressedEvent = nil
        let wasDragging = dragStarted
        dragStarted = false
        if wasDragging {
            owner?.finishTitleDrag(self, gesture: dragGesture, event: event)
            dragGesture = nil
            return
        }
        guard !wasDragging, let pressed, let native = window, native.isVisible,
            pressed.windowNumber == native.windowNumber, event.windowNumber == native.windowNumber,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            return
        }
        performClick(nil)
    }

    /// 业务作用：上下文菜单动作始终绑定右键实际指向的标签。
    /// 参数说明:
    /// - event: 当前右键事件。
    /// 返回：适用于被点击文档的操作与明确重排入口。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        var actions = [
            ("关闭", "close"), ("关闭其他", "closeOthers"), ("关闭左侧", "closeLeft"),
            ("关闭右侧", "closeRight"), ("固定 / 取消固定", "pin"),
            ("左移标签", "moveTabLeft"), ("右移标签", "moveTabRight"),
            ("移到首位", "moveTabFirst"), ("移到末位", "moveTabLast"),
            ("复制完整路径", "copyPath"), ("在 Finder 显示", "reveal"), ("克隆到分屏", "clone"),
        ]
        if owner?.canTransferTabs == true {
            actions.append(("移动到另一窗口…", "moveTabToWindow"))
        }
        for (title, id) in actions {
            let item = NSMenuItem(
                title: title,
                action: #selector(contextAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        return menu
    }

    /// 业务作用：将上下文动作连同原标签身份交给工作区。
    /// 参数说明:
    /// - sender: 用户明确选择的菜单项。
    /// 返回：只发送对应动作，不改变当前活动标签。
    @objc func contextAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onAction?(id)
        }
    }
}
