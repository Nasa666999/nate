import AppKit

@MainActor
public final class ResourceEditor: NSWindowController, NSTextViewDelegate {
    public var onSave: ((String) -> Void)?
    public let message = NSTextField(labelWithString: "完整 XML 校验通过后才会发布；原有效规则在失败时保持不变。")
    let text = NSTextView()
    let diagnosticsText = NSTextView()

    /// 业务作用：通过原生窗口编辑完整规则，字段与未知内容都可以查看和保留。
    /// 参数说明:
    /// - title: 当前资源名称。
    /// - source: 完整定义内容。
    /// 返回：独立的资源编辑窗口，正文文档不被当配置改写。
    public init(title: String, source: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 640, height: 440)
        super.init(window: window)
        let root = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = text
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = source
        text.delegate = self
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 100, height: 100)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        let save = NSButton(title: "校验并保存定义", target: self, action: #selector(saveResource))
        let diagnosticsScroll = NSScrollView()
        diagnosticsScroll.hasVerticalScroller = true
        diagnosticsScroll.documentView = diagnosticsText
        diagnosticsText.isEditable = false
        diagnosticsText.isSelectable = true
        diagnosticsText.isRichText = false
        diagnosticsText.isAutomaticLinkDetectionEnabled = false
        diagnosticsText.isAutomaticDataDetectionEnabled = false
        diagnosticsText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsText.isVerticallyResizable = true
        diagnosticsText.autoresizingMask = [.width]
        diagnosticsText.minSize = NSSize(width: 100, height: 160)
        diagnosticsText.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        diagnosticsText.textContainer?.widthTracksTextView = true
        diagnosticsText.setAccessibilityLabel("UDL 完整兼容说明")
        root.addSubview(scroll)
        root.addSubview(diagnosticsScroll)
        root.addSubview(message)
        root.addSubview(save)
        for view in [scroll, diagnosticsScroll, message, save] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: diagnosticsScroll.topAnchor, constant: -8),
            diagnosticsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            diagnosticsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            diagnosticsScroll.heightAnchor.constraint(equalToConstant: 160),
            diagnosticsScroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(lessThanOrEqualTo: save.leadingAnchor, constant: -12),
            message.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        window.contentView = root
        window.center()
        setDiagnostics([])
    }

    /// 业务作用：资源窗口由当前完整定义建立，不能恢复为独立正文状态。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：用户明确要求后才发出配置发布意图。
    /// 参数说明: 无。
    /// 返回：完整输入交由应用后台校验与安全存储。
    @objc func saveResource() {
        onSave?(text.string)
    }

    /// 业务作用：XML 编辑后撤销先前说明的有效性，异步保存不能把旧定义的结果冒充当前输入。
    /// 参数说明:
    /// - notification: 当前资源文本控件的编辑通知。
    /// 返回：清除旧字段说明并标明当前内容需要校验，不修改输入或发布配置。
    public func textDidChange(_ notification: Notification) {
        diagnosticsText.string = "当前编辑内容尚未校验。"
        message.stringValue = "当前内容已更改，请校验并保存。"
    }

    /// 业务作用：只有原始输入字节仍一致时，后台校验或持久化结果才能更新当前资源说明。
    /// 参数说明:
    /// - source: 本次后台工作固定的原 XML。
    /// - diagnostics: 同一来源的完整字段说明。
    /// - status: 该定义实际完成的保存状态。
    /// 返回：来源仍一致时更新界面并返回真；等待期间输入改变则保留当前输入与说明并返回假。
    @discardableResult
    public func applyValidation(for source: String, diagnostics: [String], status: String) -> Bool {
        // Unicode 规范等价不代表同一份 XML 字节，旧定义不能为新输入授予已校验状态。
        guard text.string.utf8.elementsEqual(source.utf8) else {
            return false
        }
        setDiagnostics(diagnostics)
        message.stringValue = status
        return true
    }

    /// 业务作用：在完整 XML 旁展示可滚动和复制的逐项兼容说明，不用单行状态截断未应用字段。
    /// 参数说明:
    /// - messages: 已验证定义及语言标题对应的完整说明，最多 8192 项和 1 MiB。
    /// 返回：只更新独立说明区域，原定义、编辑历史与正文保持不变；超量输入明确拒绝展示部分报告。
    public func setDiagnostics(_ messages: [String]) {
        guard messages.count <= 8192,
            messages.reduce(
                0,
                {
                    $0 + $1.utf8.count
                }
            ) <= 1_048_576
        else {
            diagnosticsText.string = "兼容说明超过展示容量，完整报告未显示。"
            return
        }
        diagnosticsText.string =
            messages.isEmpty
            ? "当前定义没有兼容提示。"
            : messages.enumerated().map {
                "\($0.offset + 1). \($0.element)"
            }.joined(separator: "\n\n")
    }
}
