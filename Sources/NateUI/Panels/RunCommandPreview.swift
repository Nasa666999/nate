import AppKit

@MainActor
public final class RunCommandPreview: NSWindowController, NSWindowDelegate {
    public var onConfirm: ((UUID) -> Void)?
    public var onClose: ((UUID) -> Void)?
    public let request: UUID
    private let execute = NSButton(title: "确认执行此命令", target: nil, action: nil)
    private let content = NSTextView(usingTextLayoutManager: true)
    private let status = NSTextView(usingTextLayoutManager: true)

    /// 业务作用：执行前完整展示已固定的程序、参数与目录，只有明确按钮才能授予本次进程启动资格。
    /// 参数说明:
    /// - request: 本次完整准备身份，不能复用旧窗口执行新的草稿。
    /// - name: 当前配置名称或临时运行名称。
    /// - text: 完整实际命令内容，包含已展开参数和工作目录。
    /// 返回：可复制全文、没有默认 Enter 执行动作的独立确认窗口。
    public init(request: UUID, name: String, text: String) {
        self.request = request
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "确认外部命令 · " + name
        panel.contentMinSize = NSSize(width: 700, height: 420)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let root = NSBox()
        root.boxType = .custom
        root.borderWidth = 0
        root.title = ""
        root.contentViewMargins = .zero
        root.fillColor = .windowBackgroundColor
        panel.contentView = root
        let explanation = NSTextField(
            wrappingLabelWithString:
                "以下是本次固定的实际程序、参数数组和工作目录。参数作为数据传递；若程序本身是 shell，其显式参数仍可能由该 shell 解释。确认后将启动外部进程，默认最多三十秒、保留 8 MiB 输出。"
        )
        explanation.textColor = .secondaryLabelColor
        let details = area(content)
        content.string = text
        let feedback = area(status)
        status.string = "请检查完整内容，再明确确认执行。文档、选择、草稿或配置发生变化后，原预览将失去执行资格。"
        status.textColor = .secondaryLabelColor
        execute.target = self
        execute.action = #selector(confirm)
        execute.keyEquivalent = ""
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPreview))
        cancel.keyEquivalent = "\u{1B}"
        let actions = NSStackView(views: [cancel, NSView(), execute])
        actions.spacing = 8
        let stack = NSStackView(views: [explanation, details, feedback, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            details.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            feedback.heightAnchor.constraint(equalToConstant: 52),
        ]
        for view in [explanation, details, feedback, actions] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        panel.center()
    }

    /// 业务作用：确认窗口只使用当前进程准备结果，不恢复外部界面归档的执行权。
    /// 参数说明:
    /// - coder: 系统界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：实际参数和失败原因均可完整滚动、选择与复制，长内容不会挤走执行入口。
    /// 参数说明:
    /// - text: 当前只读全文视图。
    /// 返回：具有固定布局边界的独立纯文本滚动容器。
    private func area(_ text: NSTextView) -> NSScrollView {
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        return scroll
    }

    /// 业务作用：来源改变后旧窗口保留完整可查看内容，但不能继续启动原命令。
    /// 参数说明:
    /// - message: 当前失效或执行失败的完整原因。
    /// 返回：立即关闭此窗口的执行入口，不改写原实际参数。
    public func invalidate(_ message: String) {
        execute.isEnabled = false
        status.string = message
    }

    /// 业务作用：明确按钮仅请求执行本窗口的准备身份，应用仍须复验来源与实际任务状态。
    /// 参数说明: 无。
    /// 返回：执行入口启用时发送一次确认请求。
    @objc private func confirm() {
        if execute.isEnabled {
            onConfirm?(request)
        }
    }

    /// 业务作用：取消只释放本次预览，不启动进程或改变已保存配置。
    /// 参数说明: 无。
    /// 返回：关闭当前确认窗口。
    @objc private func cancelPreview() {
        close()
    }

    /// 业务作用：关闭窗口撤销对应准备身份，旧关闭通知不能取消后来产生的新预览。
    /// 参数说明:
    /// - notification: 原生关闭通知。
    /// 返回：通知应用释放本次执行资格。
    public func windowWillClose(_ notification: Notification) {
        onClose?(request)
    }
}
