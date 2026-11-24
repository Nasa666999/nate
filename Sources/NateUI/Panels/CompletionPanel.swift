import AppKit
import NateSyntax

private final class CompletionWindow: NSPanel {
    override var canBecomeKey: Bool {
        false
    }
}

@MainActor
final class CompletionPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    let detail = NSTextField(wrappingLabelWithString: "")
    let previous = NSButton(title: "‹ 签名", target: nil, action: nil)
    let next = NSButton(title: "签名 ›", target: nil, action: nil)
    var candidates: [CompletionCandidate] = []
    var signature: SignatureHint?
    var overload = 0
    var onChoose: ((String) -> Void)?
    var confirmsTab = true
    var confirmsEnter = true

    /// 业务作用：补全面板不取得键盘焦点，普通输入与输入法继续由编辑视图持有。
    /// 参数说明: 无。
    /// 返回：具有候选、说明和重载切换的非模态面板。
    init() {
        let panel = CompletionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isFloatingPanel = true
        super.init(window: panel)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        panel.contentView = root
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = 476
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 23
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(choose)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 484).isActive = true
        root.addArrangedSubview(scroll)
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 4
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 484).isActive = true
        root.addArrangedSubview(detail)
        let buttons = NSStackView(views: [previous, next])
        for button in [previous, next] {
            button.target = self
            button.action = #selector(switchOverload(_:))
        }
        root.addArrangedSubview(buttons)
    }

    /// 业务作用：补全面板仅由编辑视图创建，不通过归档恢复旧请求。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：候选展示锚定当前视图的屏幕光标，不改变原文件和选区。
    /// 参数说明:
    /// - editor: 保持输入焦点的原视图。
    /// - values: 经过身份与修订复验的候选。
    /// - hint: 当前调用的重载与活动参数。
    /// - limited: 是否触及扫描或结果预算。
    /// 返回：非模态面板可见，没有候选或参数说明时隐藏。
    func present(in editor: EditorView, values: [CompletionCandidate], hint: SignatureHint?, limited: Bool) {
        guard !values.isEmpty || hint != nil, let panel = window, let parent = editor.window else {
            hide()
            return
        }
        if signature?.name != hint?.name {
            overload = 0
        }
        candidates = values
        signature = hint
        table.reloadData()
        if !values.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        scroll.isHidden = values.isEmpty
        previous.isHidden = (hint?.overloads.count ?? 0) < 2
        next.isHidden = previous.isHidden
        updateDetail()
        if limited {
            detail.stringValue += "\n候选或文档扫描已达预算；继续输入可缩小候选。"
        }
        let height = CGFloat(values.isEmpty ? 105 : min(9, values.count) * 23 + 105)
        let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let visible = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rect
        let origin = NSPoint(
            x: max(visible.minX, min(rect.minX, visible.maxX - 500)),
            y: max(visible.minY, min(rect.minY - height - 3, visible.maxY - height))
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 500, height: height)), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// 业务作用：面板取消后释放候选与回调，不让小窗口延长旧文档快照寿命。
    /// 参数说明: 无。
    /// 返回：面板隐藏，编辑器焦点保持原状态。
    func hide() {
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        candidates = []
        signature = nil
        onChoose = nil
    }

    /// 业务作用：只消费候选导航与用户配置的确认键，其他按键仍走原生文本输入。
    /// 参数说明:
    /// - event: 编辑器收到的按键。
    /// 返回：已消费时为真，普通输入返回假。
    func handle(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true else {
            return false
        }
        if event.keyCode == 53 {
            hide()
            return true
        }
        if !candidates.isEmpty {
            if event.keyCode == 125 || event.keyCode == 126 {
                let row = max(
                    0,
                    min(candidates.count - 1, table.selectedRow + (event.keyCode == 125 ? 1 : -1))
                )
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                return true
            }
            let tab =
                event.keyCode == 48 && confirmsTab
                && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            if tab || (event.keyCode == 36 && confirmsEnter) {
                choose()
                return true
            }
        }
        hide()
        return false
    }

    /// 业务作用：原生候选表仅枚举当前请求的有界结果。
    /// 参数说明:
    /// - tableView: 候选表。
    /// 返回：候选行数。
    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    /// 业务作用：候选名称作为可访问的原生表格单元显示。
    /// 参数说明:
    /// - tableView: 当前候选表。
    /// - tableColumn: 唯一名称列。
    /// - row: 候选索引。
    /// 返回：可读名称控件。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard candidates.indices.contains(row) else {
            return nil
        }
        return NSTextField(labelWithString: candidates[row].text)
    }

    /// 业务作用：候选改变后更新说明，不将查看行为写入正文。
    /// 参数说明:
    /// - notification: 表格选中通知。
    /// 返回：显示当前函数或文档单词来源。
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    /// 业务作用：显示全部重载中的当前签名并标明活动参数。
    /// 参数说明: 无。
    /// 返回：说明区域同步当前选中项。
    func updateDetail() {
        if let signature, !signature.overloads.isEmpty {
            overload = min(overload, signature.overloads.count - 1)
            let item = signature.overloads[overload]
            let parameters = item.parameters.joined(separator: ", ")
            let heading = "\(overload + 1)/\(signature.overloads.count) · 参数 \(signature.argument + 1) · "
            detail.stringValue =
                "\(heading)\(signature.name)(\(parameters)) → \(item.returnType)\n\(item.description)"
        }
        else if candidates.indices.contains(table.selectedRow) {
            detail.stringValue = candidates[table.selectedRow].detail
        }
        else {
            detail.stringValue = ""
        }
    }

    /// 业务作用：用户在同一调用上下文中逐个查看函数重载。
    /// 参数说明:
    /// - sender: 前一或后一签名按钮。
    /// 返回：循环切换重载，正文保持不变。
    @objc func switchOverload(_ sender: NSButton) {
        guard let count = signature?.overloads.count, count > 0 else {
            return
        }
        overload = (overload + count + (sender === next ? 1 : -1)) % count
        updateDetail()
    }

    /// 业务作用：候选确认将意图交回编辑视图复验，不直接修改独立文本副本。
    /// 参数说明: 无。
    /// 返回：有效行发送一次确认回调。
    @objc func choose() {
        guard candidates.indices.contains(table.selectedRow) else {
            return
        }
        let value = candidates[table.selectedRow].text
        let callback = onChoose
        hide()
        callback?(value)
    }
}
