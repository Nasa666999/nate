import AppKit
import NateCore

@MainActor
public final class ClipboardHistoryPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public var onPaste: ((ClipboardHistoryRecord) -> Void)?
    public var onClear: (() -> Void)?
    public var onPersistenceChange: ((Bool) -> Void)?
    public var onResetArchive: (() -> Void)?
    private let table = NSTableView()
    private let preview = NSTextView(usingTextLayoutManager: true)
    private let persistence = NSButton(checkboxWithTitle: "保存历史供下次启动使用", target: nil, action: nil)
    private let escaped = NSButton(checkboxWithTitle: "显示不可见字符", target: nil, action: nil)
    private let pasteButton = NSButton(title: "粘贴到活动文档", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空历史", target: nil, action: nil)
    private let resetButton = NSButton(title: "重新保存归档…", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var records: [ClipboardHistoryRecord] = []

    /// 业务作用：建立完整历史浏览与原形态粘贴入口，预览不拥有编辑正文或系统剪贴板的权限。
    /// 参数说明: 无。
    /// 返回：列表、全文预览、明确持久化选项和清空操作组成的独立原生面板。
    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.minSize = NSSize(width: 620, height: 380)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let root = NSBox()
        root.boxType = .custom
        root.borderWidth = 0
        root.title = ""
        root.contentViewMargins = .zero
        root.fillColor = .windowBackgroundColor
        panel.contentView = root
        let explanation = NSTextField(
            wrappingLabelWithString: "仅记录 Nate 中用户主动复制、剪切和粘贴的完整内容；不后台读取其它应用剪贴板。关闭持久化后保留已有归档，清空历史同时清空已保存记录。"
        )
        explanation.textColor = .secondaryLabelColor
        let header = NSStackView(views: [persistence, escaped])
        header.spacing = 20
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.title = "最近记录"
        column.width = 250
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false
        table.rowHeight = 29
        table.doubleAction = #selector(pasteSelected)
        table.target = self
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        preview.textContainerInset = NSSize(width: 10, height: 10)
        preview.isHorizontallyResizable = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        let detail = NSScrollView()
        detail.hasVerticalScroller = true
        detail.documentView = preview
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        let buttons = NSStackView(views: [clearButton, resetButton, NSView(), pasteButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [explanation, header, split, feedback, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        persistence.target = self
        persistence.action = #selector(togglePersistence)
        escaped.target = self
        escaped.action = #selector(toggleEscaped)
        escaped.state = .on
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelected)
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        resetButton.target = self
        resetButton.action = #selector(resetArchive)
        root.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        split.setPosition(260, ofDividerAt: 0)
        update(records: [], persisted: false, busy: false, failure: nil)
        panel.center()
    }

    /// 业务作用：历史面板由当前应用构建，不从其它归档创建可执行历史动作。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：新历史完整替换列表并按稳定记录身份保留查看位置，旧行号不能变成另一条待粘贴内容。
    /// 参数说明:
    /// - records: 当前实际保留的完整记录。
    /// - persisted: 当前明确持久化选项。
    /// - busy: 归档仍在读取、写入或确认，选项等待该动作完成。
    /// - failure: 当前归档失败说明，不包含正文或剪贴板内容。
    /// 返回：列表、全文、按钮和真实持久化状态一致更新，不抢编辑器焦点。
    public func update(records: [ClipboardHistoryRecord], persisted: Bool, busy: Bool, failure: String?) {
        let selected =
            self.records.indices.contains(table.selectedRow) ? self.records[table.selectedRow].id : nil
        self.records = records
        table.reloadData()
        if !records.isEmpty {
            let row =
                records.firstIndex {
                    $0.id == selected
                } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        persistence.state = persisted ? .on : .off
        persistence.isEnabled = !busy
        clearButton.isEnabled = !busy || !records.isEmpty
        resetButton.isHidden = failure == nil
        resetButton.isEnabled = !busy
        let bytes = records.reduce(0) {
            $0 + $1.retainedBytes
        }
        feedback.stringValue =
            "\(records.count) / 20 条 · \(bytes) / 8388608 字节" + (busy ? " · 正在确认历史归档" : "")
            + (failure.map {
                "\n" + $0
            } ?? "")
        refreshPreview()
    }

    /// 业务作用：原生列表只枚举已受容量限制的实际历史记录。
    /// 参数说明:
    /// - tableView: 请求记录数的历史列表。
    /// 返回：当前完整记录数，不查询系统剪贴板。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    /// 业务作用：列表用形态和转义摘要区分记录，NUL 与行尾不会在预览中假装为空。
    /// 参数说明:
    /// - tableView: 请求单元格的历史列表。
    /// - tableColumn: 当前唯一记录列。
    /// - row: 当前完整记录的位置。
    /// 返回：只读摘要单元格；越界时不返回其它记录。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard records.indices.contains(row) else {
            return nil
        }
        let record = records[row]
        let kind: String
        switch record.payload.shape {
        case .stream: kind = "片段"
        case .lines: kind = "整行"
        case .rectangle: kind = "矩形"
        }
        let summary = String(String.UnicodeScalarView(record.text.unicodeScalars.prefix(80)))
        let label = NSTextField(labelWithString: "[\(kind)] " + Self.visible(summary))
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// 业务作用：选择仅改变当前查看的完整记录，预览不会提前插入正文。
    /// 参数说明:
    /// - notification: 原生列表选择变化。
    /// 返回：显示该记录的全文与实际可粘贴状态。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        refreshPreview()
    }

    /// 业务作用：全文预览可切换不可见字符表示，粘贴始终使用原始载荷。
    /// 参数说明: 无。
    /// 返回：当前选择全文可查看；无记录时清空预览并禁用粘贴。
    private func refreshPreview() {
        guard records.indices.contains(table.selectedRow) else {
            preview.string = ""
            pasteButton.isEnabled = false
            return
        }
        let text = records[table.selectedRow].text
        preview.string = escaped.state == .on ? Self.visible(text) : text
        pasteButton.isEnabled = true
    }

    /// 业务作用：仅在预览中标明真实控制字符，原始内容及其行数不被改写。
    /// 参数说明:
    /// - text: 容量内的完整预览原文。
    /// 返回：保留换行布局且显示 NUL、Tab、CR 和 LF 身份的展示文字。
    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: "␀")
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "↵\n")
    }

    /// 业务作用：用户明确选中记录后把完整载荷交回应用，由实际编辑器复验目标权限。
    /// 参数说明: 无。
    /// 返回：不直接改写正文或系统剪贴板。
    @objc private func pasteSelected() {
        guard records.indices.contains(table.selectedRow) else {
            return
        }
        onPaste?(records[table.selectedRow])
    }

    /// 业务作用：用户明确请求清空当前及已保存历史，实际磁盘副作用由应用顺序执行。
    /// 参数说明: 无。
    /// 返回：发出一次明确清空意图。
    @objc private func clearHistory() {
        onClear?()
    }

    /// 业务作用：用户明确切换持久化偏好，不把关闭面板当作保存剪贴板的授权。
    /// 参数说明: 无。
    /// 返回：应用确认后的状态通过完整更新回显。
    @objc private func togglePersistence() {
        onPersistenceChange?(persistence.state == .on)
    }

    /// 业务作用：不可见字符开关仅改变全文预览。
    /// 参数说明: 无。
    /// 返回：按当前完整记录重新呈现，不生成编辑或历史记录。
    @objc private func toggleEscaped() {
        refreshPreview()
    }

    /// 业务作用：用户明确要求重建无法读取的归档时，交由应用展示具体确认与磁盘证据。
    /// 参数说明: 无。
    /// 返回：发出重建意图，不直接覆盖任何文件。
    @objc private func resetArchive() {
        onResetArchive?()
    }
}
