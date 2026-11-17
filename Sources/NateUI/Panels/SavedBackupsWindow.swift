import AppKit

public struct SavedBackupPresentation: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let timestamp: String
    public let size: String

    /// 业务作用：将保存前历史投影为只读列表，界面不持有存储路径或原文件写入权。
    /// 参数说明:
    /// - id: 当前历史内容的稳定身份。
    /// - path: 原文件的显示路径。
    /// - timestamp: 本地化保留时刻。
    /// - size: 原始字节长度的显示值。
    /// 返回：用于选择、筛选和打开独立文档的展示记录。
    public init(id: String, path: String, timestamp: String, size: String) {
        self.id = id
        self.path = path
        self.timestamp = timestamp
        self.size = size
    }
}

@MainActor
private final class SavedBackupTable: NSTableView {
    var onOpen: (() -> Void)?

    /// 业务作用：历史列表可直接用回车打开所选内容，键盘导航仍交给原生表格。
    /// 参数说明:
    /// - event: 当前原生键盘事件。
    /// 返回：回车发出打开意图，其它按键保留表格原行为。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpen?()
        }
        else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
public final class SavedBackupsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    public var onRefresh: (() -> Void)?
    public var onOpen: ((String, Int?) -> Void)?
    private let table = SavedBackupTable()
    private let filter = NSSearchField()
    private let encoding = NSPopUpButton()
    private let open = NSButton(title: "作为新文档打开", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "正在读取保存前的备份…")
    private let detail = NSTextField(wrappingLabelWithString: "选择历史内容查看完整原路径。")
    private var records: [SavedBackupPresentation] = []
    private var rows: [SavedBackupPresentation] = []
    private var explanation = ""

    /// 业务作用：浏览覆盖前的原始内容，打开动作只建立独立文档，不覆盖原目标。
    /// 参数说明:
    /// - encodings: 可供用户明确选择的文本解释方式，首项另提供自动识别。
    /// 返回：可筛选、键盘导航和手动选择编码的原生历史窗口。
    public init(encodings: [String]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "保存前备份"
        window.minSize = NSSize(width: 720, height: 360)
        window.setFrameAutosaveName("Nate.SavedBackups")
        super.init(window: window)
        let root = NSView()
        window.contentView = root
        filter.placeholderString = "筛选原路径"
        filter.delegate = self
        filter.setAccessibilityLabel("筛选保存备份原路径")
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshRecords))
        let heading = NSStackView(views: [filter, refresh])
        heading.spacing = 8
        encoding.addItems(withTitles: ["自动识别"] + encodings)
        encoding.setAccessibilityLabel("备份文本解释编码")
        encoding.toolTip = "编码仅用于新文档的解释，不改写保存的原字节。"
        open.target = self
        open.action = #selector(openSelected)
        open.isEnabled = false
        let actions = NSStackView(views: [NSTextField(labelWithString: "打开编码"), encoding, NSView(), open])
        actions.spacing = 8
        for (id, title, width) in [
            ("path", "原文件", 560.0), ("date", "保留时刻", 200.0), ("size", "原始字节", 120.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 90
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 27
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onOpen = {
            [weak self] in
            self?.openSelected()
        }
        table.setAccessibilityLabel("保存前备份列表")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 2
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        for view in [heading, scroll, detail, actions, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            heading.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            detail.heightAnchor.constraint(equalToConstant: 38),
            actions.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            actions.heightAnchor.constraint(equalToConstant: 28),
            encoding.widthAnchor.constraint(equalToConstant: 250),
            status.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(equalToConstant: 34),
        ])
        window.center()
    }

    /// 业务作用：历史窗口由当前可验证存储创建，不恢复带有失效记录身份的界面归档。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：发布最新历史展示并保留仍存在的选中身份，后台读取不抢编辑器焦点。
    /// 参数说明:
    /// - values: 已取得的当前历史记录。
    /// - message: 当前策略或读取边界的说明。
    /// 返回：按原路径筛选后更新表格和打开资格。
    public func update(_ values: [SavedBackupPresentation], message: String) {
        records = values
        explanation = message
        applyFilter()
    }

    /// 业务作用：读取中或失败时保留已展示内容，但始终显示当前真实读取状态。
    /// 参数说明:
    /// - value: 加载、取消或失败说明。
    /// 返回：状态可见；旧条目在打开时仍由应用重新核验。
    public func showStatus(_ value: String) {
        status.stringValue = value
        status.toolTip = value
    }

    /// 业务作用：筛选只影响历史展示，不删除任何原字节或改变保留策略。
    /// 参数说明:
    /// - notification: 搜索框文本变化通知。
    /// 返回：当前筛选立即更新。
    public func controlTextDidChange(_ notification: Notification) {
        applyFilter()
    }

    /// 业务作用：历史列表按用户输入的原路径筛选，并以稳定身份保留当前选择。
    /// 参数说明: 无。
    /// 返回：列表、计数和打开按钮与筛选结果一致。
    private func applyFilter() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = records.filter {
            filter.stringValue.isEmpty || $0.path.localizedStandardContains(filter.stringValue)
        }
        table.reloadData()
        if let selected,
            let index = rows.firstIndex(where: {
                $0.id == selected
            })
        {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateSelection()
        showStatus("显示 \(rows.count) / \(records.count) 份 · " + explanation)
    }

    /// 业务作用：刷新意图交回应用后台执行，界面本身不访问文件系统。
    /// 参数说明: 无。
    /// 返回：发起当前历史重新读取。
    @objc private func refreshRecords() {
        onRefresh?()
    }

    /// 业务作用：打开意图绑定当前选择及解释编码，不授予原路径覆盖权。
    /// 参数说明: 无。
    /// 返回：选择有效时请求应用建立独立文档。
    @objc private func openSelected() {
        guard rows.indices.contains(table.selectedRow) else {
            return
        }
        onOpen?(
            rows[table.selectedRow].id,
            encoding.indexOfSelectedItem > 0 ? encoding.indexOfSelectedItem - 1 : nil
        )
    }

    /// 业务作用：历史选择变化时展示完整路径，避免同名文件之间发生误选。
    /// 参数说明:
    /// - notification: 原生表格选择通知。
    /// 返回：更新详情及打开资格。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    /// 业务作用：只有当前列表中存在的历史条目可以发出打开意图。
    /// 参数说明: 无。
    /// 返回：无选择时禁用打开，有选择时显示完整来源和时刻。
    private func updateSelection() {
        open.isEnabled = rows.indices.contains(table.selectedRow)
        guard open.isEnabled else {
            detail.stringValue = "选择历史内容查看完整原路径；打开后可检查并另存为。"
            return
        }
        let row = rows[table.selectedRow]
        detail.stringValue = row.path + "\n" + row.timestamp + " · " + row.size
        detail.toolTip = detail.stringValue
    }

    /// 业务作用：原生表格只展示当前筛选后的历史数量。
    /// 参数说明:
    /// - tableView: 当前历史表格。
    /// 返回：可见行数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    /// 业务作用：按列显示历史路径、时刻和原始大小，完整来源保留为悬停说明。
    /// 参数说明:
    /// - tableView: 历史列表。
    /// - tableColumn: 原路径、保留时刻或原始字节列。
    /// - row: 当前可见历史序号。
    /// 返回：复用的只读单元格，失效序号返回空。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard rows.indices.contains(row), let column = tableColumn else {
            return nil
        }
        let label =
            tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = column.identifier
        label.lineBreakMode = column.identifier.rawValue == "path" ? .byTruncatingMiddle : .byTruncatingTail
        let value = rows[row]
        switch column.identifier.rawValue {
        case "path": label.stringValue = value.path
        case "date": label.stringValue = value.timestamp
        default: label.stringValue = value.size
        }
        label.toolTip = value.path + "\n" + value.timestamp + " · " + value.size
        return label
    }
}
