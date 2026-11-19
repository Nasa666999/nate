import AppKit
import NateCore

@MainActor
public final class MacroLibraryPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    public var onSaveCurrent: (() -> Void)?
    public var onImport: (() -> Void)?
    public var onExport: ((UUID) -> Void)?
    public var onRename: ((UUID, String) -> Void)?
    public var onDelete: ((UUID) -> Void)?
    public var onShortcut: ((UUID, MacroShortcut?) -> Void)?
    public var onPlay: ((UUID, Int, Bool) -> Void)?
    public var onStop: (() -> Void)?
    public var onReset: (() -> Void)?
    private let definitionsTable = NSTableView()
    private let actionsTable = NSTableView()
    private let preview = NSTextView(usingTextLayoutManager: true)
    private let nameField = NSTextField()
    private let shortcut = MacroShortcutCapture()
    private let repetitions = NSTextField(string: "1")
    private let untilEnd = NSButton(checkboxWithTitle: "运行至文档末尾", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存当前录制…", target: nil, action: nil)
    private let importButton = NSButton(title: "导入宏…", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出所选…", target: nil, action: nil)
    private let renameButton = NSButton(title: "重命名", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除所选", target: nil, action: nil)
    private let shortcutButton = NSButton(title: "应用快捷键", target: nil, action: nil)
    private let clearShortcutButton = NSButton(title: "清除绑定", target: nil, action: nil)
    private let playButton = NSButton(title: "在活动文档播放", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止播放", target: nil, action: nil)
    private let resetButton = NSButton(title: "重新保存当前列表…", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var definitions: [NamedMacro] = []
    private var shownID: UUID?
    private var shownName = ""
    private var shownShortcut: MacroShortcut?
    private var writable = false
    private var busy = false
    private var playing = false
    private var updating = false
    private let previewOnly: Bool
    private var renderedID: UUID?
    private var renderedAction = -1
    private var renderedArchive: Data?

    /// 业务作用：命名宏管理显示实际动作与全文详情，查看、重命名和快捷键分配不执行正文动作。
    /// 参数说明:
    /// - previewOnly: 仅预览导入文件时隐藏针对已保存库定义的管理入口。
    /// 返回：具有独立宏列表、动作列表、只读详情和明确播放按钮的原生面板。
    public init(previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 650),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = previewOnly ? "宏文件预览" : "命名宏管理"
        panel.minSize = NSSize(width: 850, height: 480)
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
            wrappingLabelWithString: "命名宏与临时录制分别保存。先查看实际动作，再明确播放到当前活动文档；载入或选择宏不会执行正文操作。"
        )
        explanation.textColor = .secondaryLabelColor
        let top = NSStackView(views: [saveButton, importButton, exportButton, NSView(), deleteButton])
        top.spacing = 8
        let definitionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macros"))
        definitionColumn.title = "已保存的宏"
        definitionColumn.width = 210
        definitionsTable.addTableColumn(definitionColumn)
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("actions"))
        actionColumn.title = "实际动作"
        actionColumn.width = 270
        actionsTable.addTableColumn(actionColumn)
        for table in [definitionsTable, actionsTable] {
            table.delegate = self
            table.dataSource = self
            table.allowsMultipleSelection = false
            table.rowHeight = 28
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.headerView = nil
        }
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = definitionsTable
        let actions = NSScrollView()
        actions.hasVerticalScroller = true
        actions.documentView = actionsTable
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
        for (title, view) in [("已保存的宏", list), ("实际动作", actions), ("完整动作详情", detail)] {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            let column = NSStackView(views: [label, view])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            split.addArrangedSubview(column)
        }
        nameField.placeholderString = "所选宏名称"
        let naming = NSStackView(views: [NSTextField(labelWithString: "名称"), nameField, renameButton])
        naming.spacing = 8
        let keys = NSStackView(views: [
            NSTextField(labelWithString: "快捷键"), shortcut, shortcutButton, clearShortcutButton, NSView(),
        ])
        keys.spacing = 8
        let playback = NSStackView(views: [
            NSTextField(labelWithString: "重复次数"), repetitions, untilEnd, playButton, stopButton, NSView(),
            resetButton,
        ])
        if previewOnly {
            saveButton.title = "保存为命名宏…"
            importButton.isHidden = true
            deleteButton.isHidden = true
            naming.isHidden = true
            keys.isHidden = true
        }
        playback.spacing = 8
        untilEnd.target = self
        untilEnd.action = #selector(changeRunMode)
        untilEnd.toolTip = "每轮完整动作后检查主光标；已经位于文末时不执行，零进展、取消或预算耗尽时停止。"
        let stack = NSStackView(views: [explanation, top, split, naming, keys, feedback, playback])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            naming.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keys.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            playback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            shortcut.widthAnchor.constraint(equalToConstant: 240),
            shortcut.heightAnchor.constraint(equalToConstant: 28),
            repetitions.widthAnchor.constraint(equalToConstant: 65),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            actions.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        for (button, selector) in [
            (saveButton, #selector(saveCurrent)), (importButton, #selector(importMacro)),
            (exportButton, #selector(exportSelected)), (renameButton, #selector(renameSelected)),
            (deleteButton, #selector(deleteSelected)), (shortcutButton, #selector(applyShortcut)),
            (clearShortcutButton, #selector(clearShortcut)), (playButton, #selector(playSelected)),
            (stopButton, #selector(stopPlayback)), (resetButton, #selector(resetArchive)),
        ] {
            button.target = self
            button.action = selector
        }
        shortcut.onError = {
            [weak self] in self?.feedback.stringValue = $0
        }
        root.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        split.setPosition(210, ofDividerAt: 0)
        split.setPosition(490, ofDividerAt: 1)
        update(
            definitions: [],
            writable: false,
            busy: true,
            canSaveCurrent: false,
            playing: false,
            failure: nil
        )
        panel.center()
    }

    /// 业务作用：宏管理只由当前应用建立，不从外部界面归档恢复执行回调。
    /// 参数说明:
    /// - coder: 系统界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：按稳定宏身份刷新列表，后台保存不丢弃用户正在输入的重命名或待应用快捷键。
    /// 参数说明:
    /// - definitions: 当前完整定义。
    /// - writable: 当前宏库是否允许保存管理。
    /// - busy: 载入、准备或保存仍未完成。
    /// - canSaveCurrent: 临时录制已停止且有实际动作。
    /// - playing: 当前有实际宏播放任务。
    /// - failure: 宏库失败或回退说明。
    /// 返回：列表、全文与管理入口一致更新，不执行宏或抢回正文焦点。
    public func update(
        definitions: [NamedMacro],
        writable: Bool,
        busy: Bool,
        canSaveCurrent: Bool,
        playing: Bool,
        failure: String?
    ) {
        let selected = selection?.id
        updating = true
        defer {
            updating = false
        }
        self.definitions = definitions
        self.writable = writable
        self.busy = busy
        self.playing = playing
        definitionsTable.reloadData()
        if !definitions.isEmpty {
            let row =
                definitions.firstIndex(where: {
                    $0.id == selected
                }) ?? 0
            definitionsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        saveButton.isEnabled = writable && !busy && !playing && canSaveCurrent
        importButton.isEnabled = writable && !busy && !playing
        resetButton.isHidden = previewOnly || writable || failure == nil
        resetButton.isEnabled = !busy && !playing
        stopButton.isEnabled = playing
        let bytes = definitions.reduce(0) {
            $0 + $1.archive.count
        }
        feedback.stringValue =
            "\(definitions.count) / 1000 个宏 · \(bytes) 字节动作归档"
            + (busy ? " · 正在确认宏库" : "") + (playing ? " · 正在播放" : "")
            + (failure.map {
                "\n" + $0
            } ?? "")
        refreshSelection()
    }

    private var selection: NamedMacro? {
        definitions.indices.contains(definitionsTable.selectedRow)
            ? definitions[definitionsTable.selectedRow] : nil
    }

    /// 业务作用：两个列表只枚举当前完整宏与所选宏的实际动作，不读取磁盘或正文。
    /// 参数说明:
    /// - tableView: 请求数量的宏列表或动作列表。
    /// 返回：对应的当前实际项数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === definitionsTable ? definitions.count : selection?.actions.count ?? 0
    }

    /// 业务作用：用名称、快捷键和动作语义区分记录，不把相同列表位置当成同一宏。
    /// 参数说明:
    /// - tableView: 请求单元格的实际列表。
    /// - tableColumn: 当前唯一描述列。
    /// - row: 当前完整列表的位置。
    /// 返回：有界只读说明；越界时为空。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        let text: String
        if tableView === definitionsTable {
            guard definitions.indices.contains(row) else {
                return nil
            }
            let macro = definitions[row]
            text =
                macro.name
                + (macro.shortcut.map {
                    " · " + MacroShortcutCapture.label($0)
                } ?? "")
        }
        else {
            guard let macro = selection, macro.actions.indices.contains(row) else {
                return nil
            }
            text = "\(row + 1). " + MacroActionPresentation.summary(macro.actions[row])
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// 业务作用：查看另一项宏或动作只改变预览，不能因双击或方向键直接播放。
    /// 参数说明:
    /// - notification: 实际列表选择变化。
    /// 返回：显示所选项的完整内容，正文保持原状。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else {
            return
        }
        if notification.object as? NSTableView === definitionsTable {
            refreshSelection()
        }
        else {
            refreshPreview()
        }
    }

    /// 业务作用：稳定身份改变时才替换名称和快捷键草稿，动作列表始终来自同一选中定义。
    /// 参数说明: 无。
    /// 返回：选择与管理按钮保持一致，不执行正文动作。
    private func refreshSelection() {
        guard let macro = selection else {
            shownID = nil
            shownName = ""
            shownShortcut = nil
            nameField.stringValue = ""
            shortcut.shortcut = nil
            shortcut.stopCapture()
            actionsTable.reloadData()
            preview.string = ""
            refreshEnabled()
            return
        }
        if shownID != macro.id {
            shortcut.stopCapture()
            nameField.stringValue = macro.name
            shortcut.shortcut = macro.shortcut
        }
        else {
            if nameField.currentEditor() == nil, nameField.stringValue.utf8.elementsEqual(shownName.utf8) {
                nameField.stringValue = macro.name
            }
            if shortcut.shortcut == shownShortcut {
                shortcut.shortcut = macro.shortcut
            }
        }
        shownID = macro.id
        shownName = macro.name
        shownShortcut = macro.shortcut
        let row = actionsTable.selectedRow
        actionsTable.reloadData()
        if !macro.actions.isEmpty {
            actionsTable.selectRowIndexes(
                IndexSet(integer: macro.actions.indices.contains(row) ? row : 0),
                byExtendingSelection: false
            )
        }
        refreshPreview()
        refreshEnabled()
    }

    /// 业务作用：只有磁盘覆盖资格、选择身份和当前任务允许时开放管理，回退库仍可查看或导出。
    /// 参数说明: 无。
    /// 返回：各按钮与真实管理能力一致。
    private func refreshEnabled() {
        let selected = selection != nil
        let changing = selected && writable && !busy && !playing
        nameField.isEnabled = changing
        renameButton.isEnabled = changing
        deleteButton.isEnabled = changing
        shortcut.isEnabled = changing
        shortcutButton.isEnabled = changing
        clearShortcutButton.isEnabled = changing
        exportButton.isEnabled = selected && !busy && !playing
        playButton.isEnabled = selected && !busy && !playing
        untilEnd.isEnabled = selected && !busy && !playing
        repetitions.isEnabled = selected && !busy && !playing && untilEnd.state != .on
    }

    /// 业务作用：完整详情只跟随已明确查看的动作，虚拟列不会提前展开成正文。
    /// 参数说明: 无。
    /// 返回：当前动作的全文与参数，无动作时清空。
    private func refreshPreview() {
        guard let macro = selection, macro.actions.indices.contains(actionsTable.selectedRow) else {
            preview.string = ""
            renderedID = nil
            renderedAction = -1
            renderedArchive = nil
            return
        }
        if renderedID == macro.id, renderedAction == actionsTable.selectedRow,
            renderedArchive == macro.archive
        {
            return
        }
        preview.string = MacroActionPresentation.detail(macro.actions[actionsTable.selectedRow])
        renderedID = macro.id
        renderedAction = actionsTable.selectedRow
        renderedArchive = macro.archive
    }

    /// 业务作用：明确保存当前临时录制，名称与保存来源由应用固定后处理。
    /// 参数说明: 无。
    /// 返回：发出一次保存请求。
    @objc private func saveCurrent() {
        if saveButton.isEnabled {
            onSaveCurrent?()
        }
    }

    /// 业务作用：用户主动选择宏文件后才允许导入，不执行导入内容。
    /// 参数说明: 无。
    /// 返回：发出一次文件选择请求。
    @objc private func importMacro() {
        if importButton.isEnabled {
            onImport?()
        }
    }

    /// 业务作用：导出只使用所选稳定身份，不读取临时录制代替当前定义。
    /// 参数说明: 无。
    /// 返回：发出完整宏导出请求。
    @objc private func exportSelected() {
        if exportButton.isEnabled, let macro = selection {
            onExport?(macro.id)
        }
    }

    /// 业务作用：重命名明确作用于当前稳定身份，用户草稿在失败时保留。
    /// 参数说明: 无。
    /// 返回：把名称交回应用完整验证。
    @objc private func renameSelected() {
        if renameButton.isEnabled, let macro = selection {
            onRename?(macro.id, nameField.stringValue)
        }
    }

    /// 业务作用：明确删除仅移除所选命名定义，不修改正文或临时录制。
    /// 参数说明: 无。
    /// 返回：发出所选身份的删除请求。
    @objc private func deleteSelected() {
        if deleteButton.isEnabled, let macro = selection {
            onDelete?(macro.id)
        }
    }

    /// 业务作用：录制键仅作为草稿，明确应用后才交由应用检查命令冲突。
    /// 参数说明: 无。
    /// 返回：请求绑定实际组合，未录制值时不解除既有绑定。
    @objc private func applyShortcut() {
        if shortcutButton.isEnabled, let macro = selection, let value = shortcut.shortcut {
            onShortcut?(macro.id, value)
        }
    }

    /// 业务作用：用户明确解除所选宏的快捷键，不改变动作内容。
    /// 参数说明: 无。
    /// 返回：发出空绑定请求。
    @objc private func clearShortcut() {
        if clearShortcutButton.isEnabled, let macro = selection {
            onShortcut?(macro.id, nil)
        }
    }

    /// 业务作用：只有明确播放按钮使用实际动作与有效次数，选择列表不承担执行副作用。
    /// 参数说明: 无。
    /// 返回：合法次数交回应用复验真实编辑目标，非法输入保留当前表单。
    @objc private func playSelected() {
        guard playButton.isEnabled, let macro = selection else {
            return
        }
        let count = untilEnd.state == .on ? 1 : Int(repetitions.stringValue)
        guard let count, (1...10_000).contains(count) else {
            feedback.stringValue = "重复次数需要一至一万。"
            return
        }
        shortcut.stopCapture()
        onPlay?(macro.id, count, untilEnd.state == .on)
    }

    /// 业务作用：明确选择文末模式后停用次数输入，避免显示与实际执行策略不一致。
    /// 参数说明: 无。
    /// 返回：仅改变播放表单，不执行正文动作。
    @objc private func changeRunMode() {
        refreshEnabled()
    }

    /// 业务作用：停止入口始终作用于真实播放任务，已完成步骤仍保留。
    /// 参数说明: 无。
    /// 返回：收回后续步骤权限的请求。
    @objc private func stopPlayback() {
        onStop?()
    }

    /// 业务作用：异常库只有用户明确选择后才进入重新保存确认流程。
    /// 参数说明: 无。
    /// 返回：不直接覆盖归档，交由应用取得原基线并确认。
    @objc private func resetArchive() {
        if resetButton.isEnabled {
            onReset?()
        }
    }

    /// 业务作用：关闭管理面板立即释放快捷键捕获，不能继续拦截其它窗口输入。
    /// 参数说明:
    /// - notification: 面板关闭通知。
    /// 返回：解除实际监听，不影响已保存宏或正文。
    public func windowWillClose(_ notification: Notification) {
        shortcut.stopCapture()
    }
}
