import AppKit

@MainActor
final class DocumentListSearch: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    private let query = NSSearchField()
    private let table = NSTableView()
    private let feedback = NSTextField(labelWithString: "")
    private let select = NSButton(title: "切换到文档", target: nil, action: nil)
    private let documents: [TabPresentation]
    private let labels: [UUID: String]
    private var matches: [TabPresentation] = []
    private var selection: UUID?

    /// 业务作用：为当前窗口的有序文档快照创建独立搜索表单。
    /// 参数说明:
    /// - documents: 按当前列表设置排序的完整标签呈现。
    /// - labels: 与标签栏共用的消歧名称和状态标记。
    /// 返回：已生成文本输入、结果行和明确确认入口的原生面板，不读取文件或正文。
    init(documents: [TabPresentation], labels: [UUID: String]) {
        self.documents = documents
        self.labels = labels
        super.init()
        panel.title = "搜索已打开文档"
        panel.minSize = NSSize(width: 460, height: 260)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        query.placeholderString = "输入文档名称或路径"
        query.setAccessibilityLabel("文档名称或路径")
        query.identifier = NSUserInterfaceItemIdentifier("documentListSearchQuery")
        query.maximumRecents = 0
        query.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("documentListSearchResults")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(acceptSelection)
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 25
        table.usesAlternatingRowBackgroundColors = true
        for (id, title, width) in [("name", "文档", 245.0), ("path", "路径", 370.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 90
            table.addTableColumn(column)
        }
        let list = NSScrollView()
        list.borderType = .bezelBorder
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.documentView = table
        feedback.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSearch))
        cancel.keyEquivalent = "\u{1b}"
        select.target = self
        select.action = #selector(acceptSelection)
        select.keyEquivalent = "\r"
        let footer = NSStackView(views: [feedback, NSView(), cancel, select])
        footer.spacing = 8
        let root = NSStackView(views: [query, list, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            query.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            list.widthAnchor.constraint(equalTo: query.widthAnchor),
            footer.widthAnchor.constraint(equalTo: query.widthAnchor),
        ])
        refreshMatches(preferred: documents.first(where: \.selected)?.id)
    }

    /// 业务作用：搜索作为原编辑窗口的附属表单暂存选择，结束后才向应用交接。
    /// 参数说明:
    /// - parent: 持有原始标签集合的编辑窗口。
    /// - onSelect: 原窗口实际结束表单后复验身份并激活的入口。
    /// 返回：显示原生表单并聚焦输入，取消时不发布任何文档身份。
    func present(in parent: NSWindow, onSelect: @escaping (UUID) -> Void) {
        parent.beginSheet(panel) { [self] response in
            panel.orderOut(nil)
            if response == .OK, let selection {
                onSelect(selection)
            }
        }
        panel.makeFirstResponder(query)
    }

    /// 业务作用：查询只比较现有名称和路径元数据，结果保持用户选择的列表顺序。
    /// 参数说明:
    /// - preferred: 优先选中的稳定身份，已经不匹配时选首项。
    /// 返回：过滤列表和确认按钮一致，无匹配时不会沿用旧选择。
    private func refreshMatches(preferred: UUID?) {
        let value = query.stringValue
        if value.isEmpty {
            matches = documents
            feedback.stringValue = "\(matches.count) 个文档"
        }
        else if value.utf8.prefix(4097).count > 4096 {
            matches = []
            feedback.stringValue = "搜索内容过长"
        }
        else {
            matches = documents.filter {
                $0.title.localizedStandardContains(value) || $0.path?.localizedStandardContains(value) == true
            }
            feedback.stringValue = matches.isEmpty ? "没有匹配的文档" : "\(matches.count) 个匹配文档"
        }
        table.reloadData()
        if !matches.isEmpty {
            let row = matches.firstIndex { $0.id == preferred } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        select.isEnabled = !matches.isEmpty
    }

    /// 业务作用：原生表格按当前查询的完整结果设置行数。
    /// 参数说明:
    /// - tableView: 展示名称与路径的结果表格。
    /// 返回：当前可选结果行数。
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    /// 业务作用：结果名称沿用标签标记，路径单独显示以区分同名文档。
    /// 参数说明:
    /// - tableView: 请求结果单元格的原生表格。
    /// - tableColumn: 名称或路径列。
    /// - row: 当前匹配列表索引。
    /// 返回：可截断但保留完整路径提示的原生文字单元格。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else {
            return nil
        }
        let tab = matches[row]
        let name = tableColumn?.identifier.rawValue == "name"
        let path = tab.path ?? "未命名临时文档"
        let text = NSTextField(labelWithString: name ? labels[tab.id] ?? tab.title : path)
        text.lineBreakMode = name ? .byTruncatingTail : .byTruncatingMiddle
        text.toolTip = name ? tab.title : path
        return text
    }

    /// 业务作用：查询编辑保持仍匹配的选择，无需在正文窗口取焦点或修改文档。
    /// 参数说明:
    /// - notification: 本搜索字段的原生文字变更通知。
    /// 返回：刷新原生结果及选择。
    func controlTextDidChange(_ notification: Notification) {
        let row = table.selectedRow
        refreshMatches(preferred: matches.indices.contains(row) ? matches[row].id : nil)
    }

    /// 业务作用：方向键浏览匹配结果，查询的输入法候选先拥有确认和取消。
    /// 参数说明:
    /// - control: 搜索输入框。
    /// - textView: 保持焦点的原生字段编辑器。
    /// - commandSelector: 本次按键解释成的编辑命令。
    /// 返回：已消费的搜索导航命令为真，普通文字处理交给系统。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else {
            return false
        }
        switch NSStringFromSelector(commandSelector) {
        case "moveUp:", "moveDown:":
            guard !matches.isEmpty else {
                return true
            }
            let next = table.selectedRow + (NSStringFromSelector(commandSelector) == "moveUp:" ? -1 : 1)
            let row = min(max(0, next), matches.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case "insertNewline:":
            acceptSelection()
        case "cancelOperation:":
            cancelSearch()
        default:
            return false
        }
        return true
    }

    /// 业务作用：确认当前结果的稳定身份，禁止空行和仍待确认的查询输入触发切换。
    /// 参数说明: 无。
    /// 返回：结束附属表单并将选中身份交给原窗口重新验证。
    @objc private func acceptSelection() {
        let row = table.selectedRow
        guard let parent = panel.sheetParent, matches.indices.contains(row),
            (query.currentEditor() as? NSTextView)?.hasMarkedText() != true
        else {
            return
        }
        selection = matches[row].id
        parent.endSheet(panel, returnCode: .OK)
    }

    /// 业务作用：取消本轮临时查询。
    /// 参数说明: 无。
    /// 返回：关闭搜索表单，不发布选择。
    @objc private func cancelSearch() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    /// 业务作用：标题栏关闭与 Esc 一样只取消本轮查询。
    /// 参数说明:
    /// - sender: 申请关闭的搜索窗口。
    /// 返回：由附属表单结束关系，系统不另行销毁。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelSearch()
        return false
    }
}
