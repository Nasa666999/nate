import AppKit
import NateCore

@MainActor
public final class RunCommandPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate
{
    public var onSave: ((RunCommandDraft) -> Void)?
    public var onPrepare: ((RunCommandDraft) -> Void)?
    public var onDelete: ((UUID) -> Void)?
    public var onImport: (() -> Void)?
    public var onExport: (() -> Void)?
    public var onApplyImport: (() -> Void)?
    public var onCancelImport: (() -> Void)?
    public var onRebuild: (() -> Void)?
    public var onInvalidate: (() -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var intentGeneration = UUID()
    private let query = NSSearchField()
    private let table = NSTableView()
    private let form = RunCommandForm()
    private let feedback = NSTextView(usingTextLayoutManager: true)
    private let save = NSButton(title: "保存当前输入", target: nil, action: nil)
    private let prepare = NSButton(title: "预览实际命令…", target: nil, action: nil)
    private let create = NSButton(title: "新建配置", target: nil, action: nil)
    private let remove = NSButton(title: "删除所选…", target: nil, action: nil)
    private let importButton = NSButton(title: "导入配置…", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出完整列表…", target: nil, action: nil)
    private let rebuild = NSButton(title: "重新保存当前列表…", target: nil, action: nil)
    private let apply = NSButton(title: "应用完整导入", target: nil, action: nil)
    private let cancel = NSButton(title: "取消导入预览", target: nil, action: nil)
    private let previewRow = NSStackView()
    private var commands: [NamedRunCommand] = []
    private var filtered: [NamedRunCommand] = []
    private var shownID: UUID?
    private var creating = false
    private var updating = false
    private var writable = false
    private var busy = true
    private var running = false
    private var previewing = false
    private var filterText = ""

    /// 业务作用：命名运行配置通过完整原生列表与表单管理，选择、导入和保存均不启动外部程序。
    /// 参数说明: 无。
    /// 返回：具有独立完整草稿、导入确认和实际命令预览入口的面板。
    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "命名运行配置"
        panel.contentMinSize = NSSize(width: 1020, height: 810)
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
                "程序、参数数组和工作目录分别保存。选择或载入配置不会执行程序；预览完整展开内容后，仍需明确确认执行。修改字段后点击保存，名称改变保留原配置身份。"
        )
        explanation.textColor = .secondaryLabelColor
        let top = NSStackView(views: [create, importButton, exportButton, NSView(), remove, rebuild])
        top.spacing = 8
        previewRow.spacing = 8
        for view in [
            NSTextField(labelWithString: "导入预览尚未应用，将完整替换已保存列表。"), NSView(), apply, cancel,
        ] {
            previewRow.addArrangedSubview(view)
        }
        query.placeholderString = "搜索名称、程序或稳定身份"
        query.maximumRecents = 0
        query.delegate = self
        table.headerView = nil
        table.rowHeight = 26
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let headings = NSStackView()
        headings.spacing = 6
        for (id, title, width) in [("name", "已保存配置", 280.0), ("program", "程序模板与快捷键", 760.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = 200
            table.addTableColumn(column)
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            headings.addArrangedSubview(label)
            if id == "name" {
                label.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
        }
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        feedback.isEditable = false
        feedback.isSelectable = true
        feedback.isRichText = false
        feedback.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        feedback.textColor = .secondaryLabelColor
        feedback.textContainerInset = NSSize(width: 6, height: 4)
        feedback.isHorizontallyResizable = false
        feedback.isVerticallyResizable = true
        feedback.autoresizingMask = [.width]
        feedback.textContainer?.widthTracksTextView = true
        let status = NSScrollView()
        status.hasVerticalScroller = true
        status.documentView = feedback
        let actions = NSStackView(views: [save, NSView(), prepare])
        actions.spacing = 8
        let stack = NSStackView(views: [
            explanation, top, previewRow, query, headings, list, form, actions, status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            status.heightAnchor.constraint(equalToConstant: 44),
        ]
        for view in [explanation, top, previewRow, query, headings, list, form, actions, status] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        for (button, action) in [
            (save, #selector(saveDraft)), (prepare, #selector(prepareDraft)), (create, #selector(newDraft)),
            (remove, #selector(deleteSelected)), (importButton, #selector(importCommands)),
            (exportButton, #selector(exportCommands)), (rebuild, #selector(rebuildCommands)),
            (apply, #selector(applyImport)), (cancel, #selector(cancelImport)),
        ] {
            button.target = self
            button.action = action
        }
        form.onEdit = {
            [weak self] in self?.onInvalidate?()
        }
        form.onError = {
            [weak self] in self?.feedback.string = $0
        }
        update(
            commands: [],
            writable: false,
            busy: true,
            running: false,
            previewing: false,
            message: "正在读取运行配置。"
        )
        panel.center()
    }

    /// 业务作用：配置管理只由当前应用建立，不从界面归档恢复外部执行入口。
    /// 参数说明:
    /// - coder: 系统归档来源。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：后台保存仅更新完整列表与状态，当前同一配置的未保存草稿保持原文。
    /// 参数说明:
    /// - commands: 完整当前列表或尚未应用的导入候选。
    /// - writable: 是否仍可覆盖磁盘原配置。
    /// - busy: 实际文件或准备任务尚未返回。
    /// - running: 已有外部进程正在运行。
    /// - previewing: 当前列表是否属于导入预览。
    /// - message: 完整保存、绑定或导入状态。
    /// 返回：原选择与草稿尽量按稳定身份保留，不显示或聚焦窗口。
    public func update(
        commands: [NamedRunCommand],
        writable: Bool,
        busy: Bool,
        running: Bool,
        previewing: Bool,
        message: String?
    ) {
        let sourceChanged = self.previewing != previewing
        self.commands = commands
        self.writable = writable
        self.busy = busy
        self.running = running
        self.previewing = previewing
        if sourceChanged {
            shownID = nil
            creating = false
        }
        feedback.string = message ?? "\(commands.count) / 256 个配置；外部命令默认最多执行三十秒、保留 8 MiB 输出。"
        previewRow.isHidden = !previewing
        window?.contentMinSize = NSSize(width: 1020, height: previewing ? 840 : 810)
        reloadFiltered()
    }

    /// 业务作用：其它管理入口按稳定身份定位具体配置，不按旧行号执行或覆盖草稿。
    /// 参数说明:
    /// - id: 当前完整列表中的明确身份。
    /// 返回：清除筛选并选择对应完整定义；不存在时保持原状态。
    public func selectCommand(_ id: UUID) {
        guard
            commands.contains(where: {
                $0.id == id
            })
        else {
            return
        }
        creating = false
        filterText = ""
        query.stringValue = ""
        filtered = commands
        updating = true
        table.reloadData()
        if let row = filtered.firstIndex(where: {
            $0.id == id
        }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updating = false
        refreshSelection()
    }

    /// 业务作用：筛选按名称、程序与身份查看原列表，不执行匹配配置。
    /// 参数说明:
    /// - notification: 当前已确认筛选编辑。
    /// 返回：最多 4 KiB 筛选参与更新，超量保留上一筛选。
    public func controlTextDidChange(_ notification: Notification) {
        guard query.stringValue.utf8.count <= 4096 else {
            feedback.string = "筛选超过 4 KiB，请缩短后继续。"
            return
        }
        intentGeneration = UUID()
        filterText = query.stringValue
        reloadFiltered()
    }

    private var selected: NamedRunCommand? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }

    /// 业务作用：完整列表重载按稳定身份保留选择，新建草稿不被后台完成自动换成第一项。
    /// 参数说明: 无。
    /// 返回：筛选列表和当前明确选择同步更新。
    private func reloadFiltered() {
        let previous = selected?.id ?? shownID
        filtered = commands.filter {
            filterText.isEmpty || $0.name.localizedStandardContains(filterText)
                || $0.executable.localizedStandardContains(filterText)
                || $0.id.uuidString.localizedStandardContains(filterText)
        }
        updating = true
        table.reloadData()
        if !creating, !filtered.isEmpty {
            let row =
                filtered.firstIndex(where: {
                    $0.id == previous
                }) ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        else {
            table.deselectAll(nil)
        }
        updating = false
        refreshSelection()
    }

    /// 业务作用：原生列表只展示已筛选的完整配置，不在绘制期间解释变量。
    /// 参数说明:
    /// - tableView: 当前列表。
    /// 返回：当前筛选后的完整项数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    /// 业务作用：程序模板与逻辑组合可直接查看，完整字段仍保留在下方编辑区。
    /// 参数说明:
    /// - tableView: 当前列表。
    /// - tableColumn: 请求的名称或程序列。
    /// - row: 当前筛选后的行号。
    /// 返回：只读名称及完整悬停内容，无效行为空。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard filtered.indices.contains(row) else {
            return nil
        }
        let command = filtered[row]
        let value =
            tableColumn?.identifier.rawValue == "name"
            ? command.name
            : command.executable
                + (command.shortcut.map {
                    " · " + NativeKeyboardShortcut.label($0)
                } ?? "")
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    /// 业务作用：选择配置只更换可见表单并撤销旧预览，双击不成为程序执行请求。
    /// 参数说明:
    /// - notification: 当前实际选择改变通知。
    /// 返回：显示明确选定的完整定义。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating {
            intentGeneration = UUID()
            creating = selected == nil
            refreshSelection()
        }
    }

    /// 业务作用：字段替换只发生在配置身份实际改变时，异步保存不能覆盖正在输入的草稿。
    /// 参数说明: 无。
    /// 返回：当前完整表单与操作权限一致更新。
    private func refreshSelection() {
        if shownID != selected?.id {
            onInvalidate?()
            shownID = selected?.id
            form.load(selected)
        }
        let changing = writable && !busy && !previewing
        form.setEditing((writable || creating) && !busy && !previewing)
        save.isEnabled = changing
        prepare.isEnabled = !busy && !running && !previewing
        create.isEnabled = !busy && !previewing
        remove.isEnabled = changing && selected != nil
        importButton.isEnabled = changing && !previewing
        exportButton.isEnabled = !busy
        rebuild.isHidden = writable || busy
        rebuild.isEnabled = !busy && !previewing
        apply.isEnabled = writable && !busy
        cancel.isEnabled = !busy
    }

    /// 业务作用：未确认候选仍属于用户输入，不能把候选之前的旧字段保存或执行。
    /// 参数说明: 无。
    /// 返回：没有输入法候选时允许读取草稿，否则显示原因并保留焦点。
    private func permitsDraft() -> Bool {
        if let client = window?.firstResponder as? any NSTextInputClient, client.hasMarkedText() {
            feedback.string = "请先完成当前输入法候选，再保存或预览配置。"
            return false
        }
        return true
    }

    /// 业务作用：新建明确释放旧选择，后续保存只能创建新的独立身份。
    /// 参数说明: 无。
    /// 返回：显示空名称和安全示例模板，不保存或执行。
    @objc private func newDraft() {
        guard create.isEnabled, permitsDraft() else {
            return
        }
        onInvalidate?()
        intentGeneration = UUID()
        creating = true
        shownID = nil
        updating = true
        table.deselectAll(nil)
        updating = false
        form.load(nil)
        refreshSelection()
    }

    /// 业务作用：一次运行入口明确建立新的临时输入，不覆盖当前已保存定义。
    /// 参数说明: 无。
    /// 返回：通道空闲且候选已完成时显示新的未保存表单。
    public func beginNewCommand() {
        newDraft()
    }

    /// 业务作用：保存提交一次完整草稿，程序和参数不在界面线程解析或执行。
    /// 参数说明: 无。
    /// 返回：具有编辑资格且候选已完成时请求完整保存。
    @objc private func saveDraft() {
        if save.isEnabled, permitsDraft() {
            onSave?(form.draft(id: shownID))
        }
    }

    /// 业务作用：预览只是准备当前完整输入，之后仍须明确确认才能启动进程。
    /// 参数说明: 无。
    /// 返回：请求准备当前固定草稿，不执行任何程序。
    @objc private func prepareDraft() {
        if prepare.isEnabled, permitsDraft() {
            onPrepare?(form.draft(id: shownID))
        }
    }

    /// 业务作用：删除请求绑定当前稳定身份，不能沿后台重排行号删除另一配置。
    /// 参数说明: 无。
    /// 返回：交由应用确认完整删除。
    @objc private func deleteSelected() {
        if remove.isEnabled, let selected {
            onDelete?(selected.id)
        }
    }

    /// 业务作用：导入先取得完整预览，不在文件选择完成后自动替换列表。
    /// 参数说明: 无。
    /// 返回：请求只读选择与解析。
    @objc private func importCommands() {
        onImport?()
    }

    /// 业务作用：导出完整当前配置列表，不把表单中尚未保存的草稿冒充已保存定义。
    /// 参数说明: 无。
    /// 返回：请求写出完整当前列表或完整导入候选。
    @objc private func exportCommands() {
        onExport?()
    }

    /// 业务作用：完整导入只有明确按钮才取得替换当前列表的资格。
    /// 参数说明: 无。
    /// 返回：请求应用完整候选，不执行候选命令。
    @objc private func applyImport() {
        onApplyImport?()
    }

    /// 业务作用：取消导入释放未应用候选，当前磁盘和实际命令保持原状。
    /// 参数说明: 无。
    /// 返回：请求恢复查看当前定义。
    @objc private func cancelImport() {
        onCancelImport?()
    }

    /// 业务作用：损坏配置的重新保存必须由应用读取新基线并明确确认。
    /// 参数说明: 无。
    /// 返回：请求重建流程，界面自身不覆盖文件。
    @objc private func rebuildCommands() {
        onRebuild?()
    }

    /// 业务作用：关闭管理窗口释放键盘捕获和只读候选的后续展示资格，已开始保存仍由应用持有。
    /// 参数说明:
    /// - notification: 原生关闭通知。
    /// 返回：停止捕获并通知应用收束只读准备。
    public func windowWillClose(_ notification: Notification) {
        form.stopCapture()
        onClose?()
    }
}
