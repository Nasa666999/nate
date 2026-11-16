import AppKit

@MainActor
public final class ResourceEditor: NSWindowController {
    public var onSave: ((String) -> Void)?
    public let message = NSTextField(labelWithString: "完整 XML 校验通过后才会发布；原有效规则在失败时保持不变。")
    let text = NSTextView()

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
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 100, height: 100)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        let save = NSButton(title: "校验并保存定义", target: self, action: #selector(saveResource))
        root.addSubview(scroll)
        root.addSubview(message)
        root.addSubview(save)
        for view in [scroll, message, save] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            message.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        window.contentView = root
        window.center()
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
}
