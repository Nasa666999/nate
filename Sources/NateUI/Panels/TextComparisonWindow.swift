import AppKit
import NateCore

@MainActor
public final class TextComparisonWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    public let comparison: TextComparison
    public let originalEditor: EditorView
    public let revisedEditor: EditorView
    public let originalScroll = NSScrollView()
    public let revisedScroll = NSScrollView()
    let split = NSSplitView()
    var positionedSplit = false
    public internal(set) var selectedChange = -1
    public var onClose: (() -> Void)?
    let changes = NSTableView()
    let summary = NSTextField(labelWithString: "")
    let previous = NSButton(
        title: "上一个变更",
        target: nil,
        action: nil
    )
    let next = NSButton(
        title: "下一个变更",
        target: nil,
        action: nil
    )
    let vertical = NSButton(
        checkboxWithTitle: "垂直同步",
        target: nil,
        action: nil
    )
    let horizontal = NSButton(
        checkboxWithTitle: "水平同步",
        target: nil,
        action: nil
    )
    var synchronizing = false

    /// 业务作用：完整差异只呈现在独立只读正文中，颜色和导航不会接触工作区原文档。
    /// 参数说明:
    /// - original: 左侧仅供本窗口持有的独立只读正文。
    /// - revised: 右侧仅供本窗口持有的独立只读正文。
    /// - comparison: 已在后台完整求解的逐行差异。
    /// - originalMarks: 绑定左侧独立正文的完整变更颜色计划。
    /// - revisedMarks: 绑定右侧独立正文的完整变更颜色计划。
    /// - originalTitle: 左侧完整来源说明。
    /// - revisedTitle: 右侧完整来源说明。
    /// - formatDetail: 两侧编码、BOM 和换行规则的独立说明。
    /// - font: 两侧共同采用的正文等宽字体。
    /// 返回：全部证据可发布时建立独立窗口，失效计划或非只读来源拒绝呈现。
    public init(
        original: DocumentBuffer,
        revised: DocumentBuffer,
        comparison: TextComparison,
        originalMarks: PreparedDocumentMarks,
        revisedMarks: PreparedDocumentMarks,
        originalTitle: String,
        revisedTitle: String,
        formatDetail: String,
        font: NSFont
    ) throws {
        // 比较窗口不借用工作区编辑器或可写缓冲区，输入、复制和导航保持独立控制身份。
        guard original !== revised, original.isReadOnly, revised.isReadOnly else {
            throw NateError.message("比较窗口需要两份独立只读正文。")
        }
        try original.commitMarks(originalMarks)
        try revised.commitMarks(revisedMarks)
        self.comparison = comparison
        originalEditor = EditorView(document: original)
        revisedEditor = EditorView(document: revised)
        let native = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1260,
                height: 740
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        native.title = "文档比较 · 只读快照"
        native.minSize = NSSize(
            width: 850,
            height: 480
        )
        super.init(window: native)
        native.delegate = self
        for (editor, scroll, label) in [
            (originalEditor, originalScroll, "比较左侧只读正文"),
            (revisedEditor, revisedScroll, "比较右侧只读正文"),
        ] {
            editor.font = font
            editor.wrapLines = false
            editor.showSymbols = true
            editor.usesDefaultKeyboardRoutes = false
            editor.setAccessibilityLabel(label)
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.setFrameSize(
                NSSize(
                    width: 500,
                    height: 600
                )
            )
            scroll.autoresizingMask = [.width, .height]
            scroll.documentView = editor
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrolled(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }
        split.frame = NSRect(
            x: 0,
            y: 0,
            width: 1001,
            height: 600
        )
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(originalScroll)
        split.addArrangedSubview(revisedScroll)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.title = "变更位置"
        column.width = 196
        changes.addTableColumn(column)
        changes.headerView = nil
        changes.rowHeight = 40
        changes.dataSource = self
        changes.delegate = self
        changes.setAccessibilityLabel("完整变更列表")
        let list = NSScrollView()
        list.documentView = changes
        list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 196).isActive = true
        let area = NSStackView(views: [list, split])
        area.orientation = .horizontal
        area.alignment = .top
        area.spacing = 8
        list.heightAnchor.constraint(equalTo: area.heightAnchor).isActive = true
        split.heightAnchor.constraint(equalTo: area.heightAnchor).isActive = true
        split.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -204).isActive = true
        for button in [previous, next] {
            button.target = self
            button.bezelStyle = .rounded
            button.isEnabled = !comparison.hunks.isEmpty
        }
        previous.action = #selector(previousChange)
        next.action = #selector(nextChange)
        vertical.state = .on
        horizontal.state = .off
        let controls = NSStackView(views: [previous, next, vertical, horizontal])
        controls.spacing = 12
        let captions = NSStackView(views: [
            Self.caption("左侧 · " + originalTitle), Self.caption("右侧 · " + revisedTitle),
        ])
        captions.distribution = .fillEqually
        captions.spacing = 16
        let listTitle = Self.caption("变更列表")
        listTitle.widthAnchor.constraint(equalToConstant: 196).isActive = true
        let titles = NSStackView(views: [listTitle, captions])
        titles.spacing = 8
        captions.widthAnchor.constraint(equalTo: titles.widthAnchor, constant: -204).isActive = true
        let detail = Self.caption(formatDetail + " · 真实换行参与比较；窗口内容不会写回源文件。")
        summary.setAccessibilityLabel("比较结果和当前变更")
        let root = NSStackView(views: [controls, titles, area, summary, detail])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(
            top: 12,
            left: 12,
            bottom: 12,
            right: 12
        )
        root.translatesAutoresizingMaskIntoConstraints = false
        // 内容区域未建立时整份窗口不发布，不能把只有工具栏或一侧正文的半成品展示为比较结果。
        guard let content = native.contentView else {
            throw NateError.message("比较窗口内容区域未建立。")
        }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            titles.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            area.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            area.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            summary.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
        ])
        summary.setContentHuggingPriority(.required, for: .vertical)
        detail.setContentHuggingPriority(.required, for: .vertical)
        changes.reloadData()
        updateSummary()
        native.center()
    }

    /// 业务作用：窗口完成实际布局后建立双侧可见宽度，零初始尺寸不能把正文窗格留在不可见状态。
    /// 参数说明:
    /// - sender: 原生显示窗口的发起者，可为空。
    /// 返回：首次显示平均分配两侧宽度，以后显示保留用户调整，正文保持只读。
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        if !positionedSplit, split.bounds.width > 0 {
            split.adjustSubviews()
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            positionedSplit = true
        }
        originalEditor.refresh()
        revisedEditor.refresh()
    }

    /// 业务作用：比较窗口只由完整不可变差异创建，未装配解码对象不能作为可用窗口。
    /// 参数说明:
    /// - coder: 原生归档解码入口。
    /// 返回：始终拒绝未持有完整来源证据的恢复路径。
    public required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：比较窗口释放时移除自身滚动观察，后续通知不能再操作旧视图。
    /// 参数说明: 无。
    /// 返回：滚动观察解除，不访问或修改源文档。
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 业务作用：来源标题保持单行有限宽度，完整路径仍可从提示和辅助功能读取。
    /// 参数说明:
    /// - text: 完整只读来源说明。
    /// 返回：不解释路径或执行链接的原生标签。
    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// 业务作用：用户关闭比较窗口后释放应用持有的独立快照，不影响源文档生命周期。
    /// 参数说明:
    /// - notification: 本窗口的关闭通知。
    /// 返回：通知所属应用释放窗口；正文和文件均不发生写入。
    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
