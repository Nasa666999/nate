import AppKit

@MainActor
final class WindowScrollSynchronization: NSObject {
    weak var primary: NSScrollView?
    weak var secondary: NSScrollView?
    var vertical = false
    var horizontal = false
    private var applying = false

    /// 业务作用：窗口只保留本次运行的双向开关，不读取偏好、保存正文或取得其它窗口的滚动控制权。
    /// 参数说明: 无。
    /// 返回：默认两个方向均关闭、没有观察目标的独立状态。
    override init() {
        super.init()
    }

    /// 业务作用：运行状态释放时解除剩余观察，旧视图通知不能延长窗口生命周期。
    /// 参数说明: 无。
    /// 返回：所有属于本状态的原生观察被移除。
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 业务作用：只为当前实际双视图登记同步来源，重新分屏先撤销旧视图的资格。
    /// 参数说明:
    /// - primary: 当前保留的第一滚动容器。
    /// - secondary: 当前新增的第二滚动容器。
    /// 返回：两个实际裁剪视图具有同步资格，已移除的容器不再参与。
    func connect(primary: NSScrollView, secondary: NSScrollView) {
        // 旧控件的观察必须先撤销，之后才把新双视图作为本窗口唯一滚动来源。
        disconnect()
        self.primary = primary
        self.secondary = secondary
        for scroll in [primary, secondary] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }
    }

    /// 业务作用：移除克隆之前先收回该视图的滚动资格，开关选择仍属于当前窗口。
    /// 参数说明: 无。
    /// 返回：没有已登记的源或目标，迟到通知不能移动保留视图。
    func disconnect() {
        // 解除观察先于释放控件引用，后续原生通知不能重新取得已移除视图的控制资格。
        NotificationCenter.default.removeObserver(self)
        primary = nil
        secondary = nil
    }

    /// 业务作用：实际视图、窗口和当前排版共同约束同步，不把其它窗口或已移除克隆当作来源。
    /// 参数说明:
    /// - notification: 两个已登记裁剪视图的原生边界通知。
    /// 返回：当前合法源推动所选方向，重入、候选、过期或脱离窗口时保持目标原位。
    @objc private func boundsChanged(_ notification: Notification) {
        // 已移除控件和其它窗口即使仍发送通知，也不能推动当前保留视图。
        guard !applying, vertical || horizontal, let primary, let secondary,
            let clip = notification.object as? NSClipView,
            clip === primary.contentView || clip === secondary.contentView,
            let first = primary.documentView as? EditorView,
            let second = secondary.documentView as? EditorView,
            let window = first.window, window.isVisible, second.window === window
        else {
            return
        }
        let source = clip === primary.contentView ? primary : secondary
        let target = source === primary ? secondary : primary
        applying = true
        defer {
            applying = false
        }
        ViewportSynchronization.apply(
            from: source,
            to: target,
            vertical: vertical,
            horizontal: horizontal,
            matchingLines: true
        )
    }
}

extension EditorWindow {
    /// 业务作用：菜单只对真实存在的双视图开放同步，不使用已移除的容器数量或旧文档状态。
    /// 参数说明: 无。
    /// 返回：当前具有两个有效正文滚动容器时为真。
    public var hasDualEditorViews: Bool {
        editorSplit.arrangedSubviews.count == 2
    }

    /// 业务作用：当前窗口独立保留垂直同步选择，恢复单视图不会把它写成全局配置。
    /// 参数说明: 无。
    /// 返回：本窗口当前垂直开关。
    public var verticalScrollSynchronized: Bool {
        scrollSynchronization.vertical
    }

    /// 业务作用：当前窗口独立保留水平同步选择，不隐式跟随垂直开关。
    /// 参数说明: 无。
    /// 返回：本窗口当前水平开关。
    public var horizontalScrollSynchronized: Bool {
        scrollSynchronization.horizontal
    }

    /// 业务作用：明确改变所选同步方向，启用本身不滚动另一视图或提交未确认输入。
    /// 参数说明:
    /// - vertical: 明确选择的垂直状态，省略时保持原开关。
    /// - horizontal: 明确选择的水平状态，省略时保持原开关。
    /// 返回：以后有效滚动使用新的方向选择，正文、光标、候选和焦点保持原状。
    public func setScrollSynchronization(vertical: Bool? = nil, horizontal: Bool? = nil) {
        if let vertical {
            scrollSynchronization.vertical = vertical
        }
        if let horizontal {
            scrollSynchronization.horizontal = horizontal
        }
    }
}
