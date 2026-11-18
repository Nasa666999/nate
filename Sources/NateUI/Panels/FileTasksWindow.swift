import AppKit

public struct FileTaskPresentation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let target: String
    public let stage: String
    public let status: String
    public let elapsed: String
    public let detail: String
    public let cancellable: Bool
    public let finished: Bool
    public let failed: Bool

    /// 业务作用：文件任务只把可读状态交给界面，不把文件句柄或发布权限传入视图。
    /// 参数说明:
    /// - id: 当前任务稳定身份。
    /// - title: 动作名称。
    /// - target: 用户确认的目标路径。
    /// - stage: 实际执行阶段。
    /// - status: 进行、完成或失败状态。
    /// - elapsed: 总等待时间。
    /// - detail: 完整失败原因和修订说明。
    /// - cancellable: 是否仍可撤销本次发布权。
    /// - finished: 系统动作是否已经真正结束。
    /// - failed: 是否存在需要处理的实际失败。
    /// 返回：不可变展示值，界面动作仍按任务身份回传应用。
    public init(
        id: UUID,
        title: String,
        target: String,
        stage: String,
        status: String,
        elapsed: String,
        detail: String,
        cancellable: Bool,
        finished: Bool,
        failed: Bool
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.stage = stage
        self.status = status
        self.elapsed = elapsed
        self.detail = detail
        self.cancellable = cancellable
        self.finished = finished
        self.failed = failed
    }
}

@MainActor
public final class FileTasksWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    public var onRefresh: (() -> Void)?
    public var onCancel: ((UUID) -> Void)?
    public var onClearCompleted: (() -> Void)?
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "进行中 0 · 已完成 0")
    private let execution = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "选择任务查看完整目标和失败原因。")
    private let cancel = NSButton(title: "撤销本次发布", target: nil, action: nil)
    private let clear = NSButton(title: "清除已完成记录", target: nil, action: nil)
    private var rows: [FileTaskPresentation] = []
    private var refreshTask: Task<Void, Never>?

    /// 业务作用：集中显示原文件与配置写入的真实阶段，取消不会把未返回的系统动作藏起来。
    /// 参数说明: 无。
    /// 返回：可观察和撤销待发布请求的独立原生窗口。
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "文件写入任务"
        window.minSize = NSSize(width: 780, height: 300)
        window.setFrameAutosaveName("Nate.FileTasks")
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        window.contentView = root
        status.font = .systemFont(ofSize: 12)
        cancel.target = self
        cancel.action = #selector(cancelSelected)
        cancel.isEnabled = false
        cancel.toolTip = "撤销尚未使用的发布权；系统调用返回前，任务继续显示为进行中。"
        clear.target = self
        clear.action = #selector(clearCompleted)
        let heading = NSStackView(views: [status, NSView(), clear, cancel])
        heading.orientation = .horizontal
        heading.spacing = 8
        for (id, title, width) in [
            ("title", "动作", 150.0), ("target", "目标", 310.0), ("stage", "实际阶段", 160.0),
            ("status", "状态", 200.0), ("elapsed", "总等待", 90.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 70
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("文件写入任务列表")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 3
        execution.font = .systemFont(ofSize: 11)
        execution.textColor = .secondaryLabelColor
        execution.maximumNumberOfLines = 4
        for view in [heading, execution, scroll, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            execution.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            execution.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            execution.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            execution.heightAnchor.constraint(equalToConstant: 64),
            scroll.topAnchor.constraint(equalTo: execution.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            detail.heightAnchor.constraint(equalToConstant: 54),
        ])
        window.center()
    }

    /// 业务作用：任务视图由当前应用状态装配，不恢复含旧权限的归档对象。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：显示窗口时恢复观察，隐藏或关闭后不留下持续刷新任务。
    /// 参数说明:
    /// - sender: 发出显示意图的界面对象。
    /// 返回：窗口可见并按固定周期读取最新展示值。
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshTask?.cancel()
        refreshTask = Task {
            [weak self] in
            while !Task.isCancelled {
                guard self?.refreshIfVisible() == true else {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                }
                catch {
                    break
                }
            }
        }
    }

    /// 业务作用：将最新记录投影到表格并按稳定任务身份保留选中项，不抢编辑器焦点。
    /// 参数说明:
    /// - values: 当前所有在途记录及有限完成历史。
    /// 返回：表格和可用动作反映真实执行状态。
    public func update(_ values: [FileTaskPresentation]) {
        guard rows != values else {
            return
        }
        let selected =
            table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        let sameOrder = rows.map(\.id) == values.map(\.id)
        rows = values
        if sameOrder {
            // 只有文本状态变化时保留原生行身份，辅助功能和正在进行的用户选择不会随计时刷新失效。
            for row in rows.indices {
                for column in table.tableColumns.indices {
                    if let label = table.view(atColumn: column, row: row, makeIfNecessary: false)
                        as? NSTextField
                    {
                        configure(label, for: rows[row], column: table.tableColumns[column].identifier)
                    }
                }
            }
        }
        else {
            table.reloadData()
            if let selected,
                let index = rows.firstIndex(where: {
                    $0.id == selected
                })
            {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        let active = rows.filter {
            !$0.finished
        }.count
        status.stringValue = "进行中 \(active) · 已完成 \(rows.count - active)"
        updateSelection()
    }

    /// 业务作用：显示系统调用未返回和队列隔离情况，用户可区分文件失败与执行通道耗尽。
    /// 参数说明:
    /// - value: 应用根据各独立 I/O 通道生成的只读状态。
    /// 返回：不重建任务行，仅更新执行通道说明。
    public func updateExecutionStatus(_ value: String) {
        execution.stringValue = value
        execution.toolTip = value
    }

    /// 业务作用：仅在窗口可见时发出只读刷新意图，弱引用不会跨睡眠持有控制器。
    /// 参数说明: 无。
    /// 返回：窗口仍可见时继续观察，否则结束周期任务。
    private func refreshIfVisible() -> Bool {
        guard window?.isVisible == true else {
            return false
        }
        onRefresh?()
        return true
    }

    /// 业务作用：关闭窗口只停止观察，不取消业务文件任务。
    /// 参数说明:
    /// - notification: 原生窗口关闭通知。
    /// 返回：释放刷新任务，实际 I/O 由应用继续登记。
    public func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 业务作用：选中任务改变时只更新详情和撤销资格，不改变请求本身。
    /// 参数说明:
    /// - notification: 原生表格选择通知。
    /// 返回：详情与动作绑定当前选中任务。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    /// 业务作用：任务进入发布后禁用撤销，未决系统动作继续明确显示。
    /// 参数说明: 无。
    /// 返回：按钮可用性和完整说明同步更新。
    private func updateSelection() {
        guard rows.indices.contains(table.selectedRow) else {
            cancel.isEnabled = false
            detail.stringValue = "选择任务查看完整目标和失败原因。"
            detail.toolTip = nil
            return
        }
        let row = rows[table.selectedRow]
        cancel.isEnabled = row.cancellable
        detail.stringValue = row.target + "\n" + row.detail
        detail.toolTip = detail.stringValue
    }

    /// 业务作用：撤销意图携带任务身份，应用在动作时重新核验实际发布状态。
    /// 参数说明: 无。
    /// 返回：只对当前仍可撤销的任务发出请求。
    @objc private func cancelSelected() {
        guard rows.indices.contains(table.selectedRow), rows[table.selectedRow].cancellable else {
            return
        }
        onCancel?(rows[table.selectedRow].id)
        onRefresh?()
    }

    /// 业务作用：清理展示历史不影响在途请求或文件内容。
    /// 参数说明: 无。
    /// 返回：交回应用清理已完成记录后重新刷新。
    @objc private func clearCompleted() {
        onClearCompleted?()
        onRefresh?()
    }

    /// 业务作用：表格行数完全来自已发布任务展示值。
    /// 参数说明:
    /// - tableView: 当前任务表格。
    /// 返回：可见任务总数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    /// 业务作用：复用原生文本单元格呈现阶段与实际结果，完整目标保留在悬停说明。
    /// 参数说明:
    /// - tableView: 当前任务表格。
    /// - tableColumn: 动作、目标、阶段、状态或等待时间列。
    /// - row: 当前展示记录序号。
    /// 返回：对应列的只读状态视图。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard rows.indices.contains(row), let column = tableColumn else {
            return nil
        }
        let value = rows[row]
        let label =
            tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = column.identifier
        configure(label, for: value, column: column.identifier)
        return label
    }

    /// 业务作用：同一原生单元格只更新显示值，计时变化不重建行或丢失辅助功能身份。
    /// 参数说明:
    /// - label: 现有或新建的只读单元格。
    /// - value: 对应任务的固定展示值。
    /// - column: 当前状态列。
    /// 返回：更新文本、颜色与完整说明。
    private func configure(
        _ label: NSTextField,
        for value: FileTaskPresentation,
        column: NSUserInterfaceItemIdentifier
    ) {
        label.lineBreakMode = column.rawValue == "target" ? .byTruncatingMiddle : .byTruncatingTail
        label.textColor = value.failed ? .systemRed : .labelColor
        switch column.rawValue {
        case "title": label.stringValue = value.title
        case "target": label.stringValue = value.target
        case "stage": label.stringValue = value.stage
        case "status": label.stringValue = value.status
        default: label.stringValue = value.elapsed
        }
        label.toolTip = value.target + "\n" + value.detail
    }
}
