import AppKit
import NateCore

@MainActor
public final class KeyboardMapPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate
{
    public var onChange: ((String, [KeyboardShortcut]?) -> Void)?
    public var onImport: (() -> Void)?
    public var onExport: (() -> Void)?
    public var onRestoreAll: (() -> Void)?
    public var onRebuild: (() -> Void)?
    public var onManageExternal: ((String) -> Void)?
    public var onApplyImport: (() -> Void)?
    public var onCancelImport: (() -> Void)?
    public var onClose: (() -> Void)?
    private let query = NSSearchField()
    private let table = NSTableView()
    private let details = NSTextView(usingTextLayoutManager: true)
    private let feedback = NSTextView(usingTextLayoutManager: true)
    private let capture = MacroShortcutCapture()
    private let bindings = NSPopUpButton()
    private let addButton = NSButton(title: "添加组合", target: nil, action: nil)
    private let replaceButton = NSButton(title: "替换所选组合", target: nil, action: nil)
    private let removeButton = NSButton(title: "删除所选组合", target: nil, action: nil)
    private let defaultButton = NSButton(title: "恢复所选默认", target: nil, action: nil)
    private let disableButton = NSButton(title: "清空所选绑定", target: nil, action: nil)
    private let externalButton = NSButton(title: "在宏管理中设置…", target: nil, action: nil)
    private let importButton = NSButton(title: "导入映射…", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出用户覆盖…", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复全部默认…", target: nil, action: nil)
    private let rebuildButton = NSButton(title: "重新保存当前映射…", target: nil, action: nil)
    private let applyImportButton = NSButton(title: "应用完整导入", target: nil, action: nil)
    private let cancelImportButton = NSButton(title: "取消预览", target: nil, action: nil)
    private let previewRow = NSStackView()
    private var commands: [KeyboardCommandPresentation] = []
    private var filtered: [KeyboardCommandPresentation] = []
    private var shownID: String?
    private var shownBindings: [KeyboardShortcut] = []
    private var writable = false
    private var busy = true
    private var updating = false
    private var filterText = ""

    /// 业务作用：快捷键管理只查看完整命令及配置，选择、搜索或捕获组合不执行所选命令。
    /// 参数说明: 无。
    /// 返回：独立原生命令列表、完整详情、逐项组合管理及导入导出入口。
    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "快捷键映射器"
        panel.minSize = NSSize(width: 1020, height: 760)
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
            wrappingLabelWithString: "按名称、菜单或命令身份筛选。一个命令可配置多个组合；查看或导入配置不会执行命令。空绑定取消默认组合，恢复默认移除该项覆盖。"
        )
        explanation.textColor = .secondaryLabelColor
        let top = NSStackView(views: [importButton, exportButton, NSView(), restoreButton, rebuildButton])
        top.spacing = 8
        previewRow.spacing = 8
        for view in [
            NSTextField(labelWithString: "正在预览；实际组合仍使用原配置。"), NSView(),
            applyImportButton, cancelImportButton,
        ] {
            previewRow.addArrangedSubview(view)
        }
        query.placeholderString = "搜索命令、菜单或稳定身份"
        query.maximumRecents = 0
        query.delegate = self
        table.headerView = nil
        table.rowHeight = 28
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let headings = NSStackView()
        headings.spacing = 6
        for (identifier, title, width) in [
            ("command", "命令", 300.0), ("keys", "实际启用组合", 340.0), ("category", "所属菜单", 220.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            column.minWidth = identifier == "command" ? 220 : 120
            table.addTableColumn(column)
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            headings.addArrangedSubview(label)
            if identifier != "category" {
                label.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
        }
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.hasHorizontalScroller = true
        list.documentView = table
        let detailScroll = textArea(details)
        let feedbackScroll = textArea(feedback)
        feedback.textColor = .secondaryLabelColor
        let current = NSStackView(views: [
            NSTextField(labelWithString: "当前期望组合"), bindings, removeButton, defaultButton, disableButton,
            NSView(),
        ])
        current.spacing = 8
        let editing = NSStackView(views: [
            NSTextField(labelWithString: "待应用组合"), capture, addButton, replaceButton, NSView(),
            externalButton,
        ])
        editing.spacing = 8
        let stack = NSStackView(views: [
            explanation, top, previewRow, query, headings, list, detailScroll, current, editing,
            feedbackScroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            detailScroll.heightAnchor.constraint(equalToConstant: 125),
            feedbackScroll.heightAnchor.constraint(equalToConstant: 62),
            bindings.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            capture.widthAnchor.constraint(equalToConstant: 240),
            capture.heightAnchor.constraint(equalToConstant: 28),
        ]
        for view in [
            explanation, top, previewRow, query, headings, list, detailScroll, current, editing,
            feedbackScroll,
        ] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        for (button, selector) in [
            (addButton, #selector(addBinding)), (replaceButton, #selector(replaceBinding)),
            (removeButton, #selector(removeBinding)), (defaultButton, #selector(restoreSelected)),
            (disableButton, #selector(disableSelected)), (externalButton, #selector(manageExternal)),
            (importButton, #selector(importMapping)), (exportButton, #selector(exportMapping)),
            (restoreButton, #selector(restoreAll)), (rebuildButton, #selector(rebuild)),
            (applyImportButton, #selector(applyImport)), (cancelImportButton, #selector(cancelImport)),
        ] {
            button.target = self
            button.action = selector
        }
        capture.onError = {
            [weak self] in self?.feedback.string = $0
        }
        update(commands: [], writable: false, busy: true, message: "正在读取快捷键设置。")
        panel.center()
    }

    /// 业务作用：命令管理由当前应用提供完整回调，不从外部界面归档恢复执行入口。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：完整配置与冲突详情始终可滚动读取和复制，长错误不能挤走管理按钮。
    /// 参数说明:
    /// - text: 承载完整原文的只读文字视图。
    /// 返回：具有独立垂直滚动的全文容器。
    private func textArea(_ text: NSTextView) -> NSScrollView {
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

    /// 业务作用：后台设置完成只更新原稳定命令，搜索原文、待应用组合和窗口焦点保持当前用户意图。
    /// 参数说明:
    /// - commands: 实际目录与不可用覆盖的完整呈现。
    /// - writable: 当前磁盘配置允许继续覆盖。
    /// - busy: 实际载入或保存任务尚未返回。
    /// - message: 全文状态与保存失败说明。
    /// - previewing: 当前期望是否来自尚未应用的完整导入。
    /// 返回：列表和管理入口一致更新，不执行任何命令或主动显示窗口。
    public func update(
        commands: [KeyboardCommandPresentation],
        writable: Bool,
        busy: Bool,
        message: String?,
        previewing: Bool = false
    ) {
        self.commands = commands
        self.writable = writable
        self.busy = busy
        feedback.string = message ?? "\(commands.count) 个命令；每个命令最多十六个组合。"
        reloadFiltered()
        importButton.isEnabled = writable && !busy
        exportButton.isEnabled = !busy
        restoreButton.isEnabled = writable && !busy
        rebuildButton.isHidden = writable || busy
        rebuildButton.isEnabled = !busy
        previewRow.isHidden = !previewing
        applyImportButton.isEnabled = writable && !busy
        cancelImportButton.isEnabled = !busy
        restoreButton.isEnabled = writable && !busy && !previewing
        importButton.isEnabled = writable && !busy && !previewing
    }

    private var selected: KeyboardCommandPresentation? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }

    /// 业务作用：筛选只比较当前名称、类别和稳定身份，超长输入不触发逐项放大的匹配计算。
    /// 参数说明:
    /// - notification: 当前搜索字段的已确认编辑通知。
    /// 返回：最多 4 KiB 筛选参与列表更新，超量保留上一份筛选并显示原因。
    public func controlTextDidChange(_ notification: Notification) {
        guard query.stringValue.utf8.count <= 4096 else {
            feedback.string = "筛选条件超过 4 KiB，请缩短后继续。"
            return
        }
        filterText = query.stringValue
        reloadFiltered()
    }

    /// 业务作用：筛选和异步重载按稳定身份保留选择，另一项命令不能继承先前待应用组合。
    /// 参数说明: 无。
    /// 返回：当前可见命令更新，实际选择改变时撤去旧捕获状态。
    private func reloadFiltered() {
        let original = selected?.id ?? shownID
        filtered = commands.filter {
            filterText.isEmpty || $0.title.localizedStandardContains(filterText)
                || $0.category.localizedStandardContains(filterText)
                || $0.id.localizedStandardContains(filterText)
        }
        updating = true
        table.reloadData()
        let index = original.flatMap {
            id in
            filtered.firstIndex {
                $0.id == id
            }
        }
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: index ?? 0), byExtendingSelection: false)
        }
        updating = false
        refreshSelection()
    }

    /// 业务作用：原生列表只读取完整目录呈现，不在绘制期间解析配置或执行命令。
    /// 参数说明:
    /// - tableView: 当前命令表格。
    /// 返回：当前筛选后的完整命令数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    /// 业务作用：列表显示实际启用组合，完整默认、期望和冲突在下方全文中保留。
    /// 参数说明:
    /// - tableView: 当前原生表格。
    /// - tableColumn: 请求的命令、实际键或类别列。
    /// - row: 当前筛选中的稳定记录位置。
    /// 返回：只读单行名称与完整悬停内容，无效行为空。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard filtered.indices.contains(row) else {
            return nil
        }
        let command = filtered[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "keys":
            value =
                command.active.isEmpty
                ? "未启用组合"
                : command.active.map {
                    NativeKeyboardShortcut.label($0)
                }.joined(separator: "、")
        case "category": value = command.category
        default: value = command.title
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    /// 业务作用：选择只更新当前命令的配置详情，不把双击或方向选择当成执行请求。
    /// 参数说明:
    /// - notification: 原生表格选择通知。
    /// 返回：刷新同一稳定命令的组合列表。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating {
            refreshSelection()
        }
    }

    /// 业务作用：删除和替换始终绑定原实际组合，后台重排不沿旧索引操作另一项键位。
    /// 参数说明: 无。
    /// 返回：完整详情、组合菜单和可操作状态同步更新。
    private func refreshSelection() {
        let previous =
            shownBindings.indices.contains(bindings.indexOfSelectedItem)
            ? shownBindings[bindings.indexOfSelectedItem] : nil
        let command = selected
        if shownID != command?.id {
            capture.stopCapture()
            capture.shortcut = nil
        }
        shownID = command?.id
        shownBindings =
            command.map {
                $0.requested ?? $0.defaults
            } ?? []
        bindings.removeAllItems()
        bindings.addItems(
            withTitles: shownBindings.map {
                NativeKeyboardShortcut.label($0)
            }
        )
        if let previous, let index = shownBindings.firstIndex(of: previous) {
            bindings.selectItem(at: index)
        }
        let changing = command?.available == true && command?.managedElsewhere == false && writable && !busy
        capture.isEnabled = changing
        addButton.isEnabled = changing
        replaceButton.isEnabled = changing && !shownBindings.isEmpty
        removeButton.isEnabled = changing && !shownBindings.isEmpty
        disableButton.isEnabled = changing
        defaultButton.isEnabled =
            command?.requested != nil && writable && !busy
        externalButton.isHidden = command?.managedElsewhere != true
        externalButton.isEnabled = command?.available == true && !busy
        guard let command else {
            details.string = "没有符合筛选的命令。"
            return
        }
        let show: ([KeyboardShortcut]) -> String = {
            $0.map {
                NativeKeyboardShortcut.label($0)
            }.joined(separator: "、")
        }
        details.string =
            command.title + "\n身份：" + command.id + "\n菜单：" + command.category
            + "\n默认：" + show(command.defaults) + "\n期望：" + show(command.requested ?? command.defaults)
            + "\n实际启用：" + show(command.active)
            + (command.available ? "" : "\n当前应用未提供该命令，保留覆盖且不执行。")
            + (command.managedElsewhere ? "\n此命令由宏管理保存绑定。" : "")
            + (command.notes.isEmpty ? "" : "\n" + command.notes.joined(separator: "\n"))
    }

    /// 业务作用：新增组合以当前命令完整列表为基础，重复和超量在提交前拒绝。
    /// 参数说明: 无。
    /// 返回：有效待应用组合产生一项完整更新请求。
    @objc private func addBinding() {
        guard addButton.isEnabled, let command = selected, let value = capture.shortcut else {
            feedback.string = "请先点击录制一个待应用组合。"
            return
        }
        guard !shownBindings.contains(value), shownBindings.count < KeyboardMap.maximumBindingsPerCommand
        else {
            feedback.string = "组合已经存在，或本命令已达到十六项。"
            return
        }
        capture.stopCapture()
        onChange?(command.id, shownBindings + [value])
    }

    /// 业务作用：替换当前明确选择的组合，保留其它组合及其顺序。
    /// 参数说明: 无。
    /// 返回：有实际目标与待应用组合时请求完整更新。
    @objc private func replaceBinding() {
        guard replaceButton.isEnabled, let command = selected, let value = capture.shortcut,
            shownBindings.indices.contains(bindings.indexOfSelectedItem)
        else {
            feedback.string = "请选择原组合并录制待应用组合。"
            return
        }
        var next = shownBindings
        next[bindings.indexOfSelectedItem] = value
        guard Set(next).count == next.count else {
            feedback.string = "替换后的组合与本命令其它绑定重复。"
            return
        }
        capture.stopCapture()
        onChange?(command.id, next)
    }

    /// 业务作用：删除按当前组合列表确认的单项绑定，最后一项删除后明确禁用默认组合。
    /// 参数说明: 无。
    /// 返回：请求保存完整剩余列表。
    @objc private func removeBinding() {
        guard removeButton.isEnabled, let command = selected,
            shownBindings.indices.contains(bindings.indexOfSelectedItem)
        else {
            return
        }
        var next = shownBindings
        next.remove(at: bindings.indexOfSelectedItem)
        onChange?(command.id, next)
    }

    /// 业务作用：恢复所选默认移除该项用户覆盖，当前应用的默认定义重新生效。
    /// 参数说明: 无。
    /// 返回：请求移除原覆盖，不执行命令。
    @objc private func restoreSelected() {
        if defaultButton.isEnabled, let command = selected {
            onChange?(command.id, nil)
        }
    }

    /// 业务作用：清空所选命令的全部组合，不把空列表误当成恢复默认。
    /// 参数说明: 无。
    /// 返回：请求保存明确的空绑定。
    @objc private func disableSelected() {
        if disableButton.isEnabled, let command = selected {
            onChange?(command.id, [])
        }
    }

    /// 业务作用：独立命令库保持唯一绑定来源，用户可明确进入原管理入口。
    /// 参数说明: 无。
    /// 返回：请求查看对应命令库，不执行命令。
    @objc private func manageExternal() {
        if externalButton.isEnabled, let command = selected {
            onManageExternal?(command.id)
        }
    }

    /// 业务作用：导入入口只请求完整读取与预览，不执行归档中的命令身份。
    /// 参数说明: 无。
    /// 返回：由应用处理用户明确选择的文件。
    @objc private func importMapping() {
        onImport?()
    }

    /// 业务作用：导出完整用户覆盖，冲突或不可用记录仍保留以便检查。
    /// 参数说明: 无。
    /// 返回：请求写出当前完整归档。
    @objc private func exportMapping() {
        onExport?()
    }

    /// 业务作用：全部恢复交由应用确认完整配置变更，不逐项产生部分默认状态。
    /// 参数说明: 无。
    /// 返回：请求明确确认后的整份默认映射。
    @objc private func restoreAll() {
        onRestoreAll?()
    }

    /// 业务作用：不可读设置只能明确重建，普通管理不取得自动覆盖权限。
    /// 参数说明: 无。
    /// 返回：请求重新保存当前完整配置的确认流程。
    @objc private func rebuild() {
        onRebuild?()
    }

    /// 业务作用：完整导入必须由明确按钮取得应用资格，预览和筛选不能发布配置。
    /// 参数说明: 无。
    /// 返回：请求保存当前完整候选。
    @objc private func applyImport() {
        onApplyImport?()
    }

    /// 业务作用：取消导入只释放候选，当前磁盘与执行绑定保持原状。
    /// 参数说明: 无。
    /// 返回：请求撤去未应用预览。
    @objc private func cancelImport() {
        onCancelImport?()
    }

    /// 业务作用：关闭窗口释放组合捕获，后续窗口的按键恢复正常分发。
    /// 参数说明:
    /// - notification: 原生关闭通知。
    /// 返回：解除实际本地键盘监视。
    public func windowWillClose(_ notification: Notification) {
        capture.stopCapture()
        onClose?()
    }
}
