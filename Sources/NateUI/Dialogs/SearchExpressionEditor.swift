import AppKit

@MainActor
final class SearchExpressionEditor: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let text = NSTextView(usingTextLayoutManager: true)
    var onComplete: ((String?) -> Void)?

    /// 业务作用：为完整搜索和替换输入提供滚动的多行原文编辑，不用单行控件测量全部内容。
    /// 参数说明:
    /// - value: 未转义、未归一化的完整表达式。
    /// 返回：固定视口的原文编辑窗口，编辑期间不改变搜索条件。
    init(value: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "编辑完整输入"
        panel.minSize = NSSize(width: 480, height: 260)
        super.init(window: panel)
        panel.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.delegate = self
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.string = value
        scroll.documentView = text
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelInput))
        let accept = NSButton(title: "使用全文", target: self, action: #selector(acceptInput))
        accept.keyEquivalent = "\r"
        accept.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [cancel, accept])
        buttons.spacing = 8
        let root = NSStackView(views: [scroll, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            ])
        }
    }

    /// 业务作用：全文编辑窗口由原查询建立，不从归档恢复未确认输入。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：把完整输入编辑绑定到当前查找窗口，保持原窗口的执行条件直到确认。
    /// 参数说明:
    /// - parent: 持有输入组件的窗口。
    /// 返回：以附属窗口或独立窗口显示，并将焦点交给原文。
    func present(attachedTo parent: NSWindow?) {
        guard let window else {
            return
        }
        if let parent {
            parent.beginSheet(window)
        }
        else {
            showWindow(nil)
        }
        window.makeFirstResponder(text)
    }

    /// 业务作用：确认完整输入前提交当前输入法候选，只有显式确认才更新原查询。
    /// 参数说明: 无。
    /// 返回：原始多行内容交回输入组件，编辑窗口关闭。
    @objc private func acceptInput() {
        text.unmarkText()
        finish(text.string)
    }

    /// 业务作用：取消全文编辑，保留原搜索条件。
    /// 参数说明: 无。
    /// 返回：编辑窗口关闭且不发布本轮草稿。
    @objc func cancelInput() {
        finish(nil)
    }

    /// 业务作用：标题栏关闭等同取消，不能将未确认草稿带入搜索。
    /// 参数说明:
    /// - sender: 当前全文编辑窗口。
    /// 返回：由取消路径结束附属窗口，系统不再另行关闭。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    /// 业务作用：多行输入保留 Enter 换行，Esc 在输入法候选处理之后才取消全文草稿。
    /// 参数说明:
    /// - textView: 当前原文编辑器。
    /// - commandSelector: 原生输入命令。
    /// 返回：无候选时的取消由窗口处理，其余保留原生文字输入。
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), NSStringFromSelector(commandSelector) == "cancelOperation:" else {
            return false
        }
        finish(nil)
        return true
    }

    /// 业务作用：先结束附属关系，再交还输入结果，避免释放持有者时留下未结束的窗口。
    /// 参数说明:
    /// - value: 确认后的完整原文；空值表示取消。
    /// 返回：完成回调至多执行一次。
    private func finish(_ value: String?) {
        let completion = onComplete
        onComplete = nil
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        completion?(value)
    }
}
