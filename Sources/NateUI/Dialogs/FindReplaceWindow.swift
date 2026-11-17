import AppKit
import NateSearch

@MainActor
public final class FindReplaceWindow: NSWindowController, NSTextFieldDelegate {
    public var onAction: ((String, SearchOptions, String, String) -> Void)?
    public var onDismiss: (() -> Void)?
    public let feedback = NSTextField(wrappingLabelWithString: "输入查找内容。普通模式按字面查找，扩展模式解释反斜杠转义。")
    let query = SearchInputBox(frame: .zero)
    let replacement = SearchInputBox(frame: .zero)
    let directory = SearchInputBox(frame: .zero)
    let filters = SearchInputBox(frame: .zero)
    let mode = NSPopUpButton()
    let caseSensitive = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    let wholeWord = NSButton(checkboxWithTitle: "全词匹配", target: nil, action: nil)
    let dot = NSButton(checkboxWithTitle: "点匹配换行", target: nil, action: nil)
    let backwards = NSButton(checkboxWithTitle: "反向", target: nil, action: nil)
    let wrap = NSButton(checkboxWithTitle: "循环查找", target: nil, action: nil)
    let selection = NSButton(checkboxWithTitle: "选区内（批量操作）", target: nil, action: nil)
    let recursive = NSButton(checkboxWithTitle: "递归子目录", target: nil, action: nil)
    let includeHidden = NSButton(checkboxWithTitle: "包含隐藏项", target: nil, action: nil)
    let diskBuffers = NSButton(checkboxWithTitle: "文件查找按磁盘内容搜索已打开文件", target: nil, action: nil)
    var previousButton: NSButton?
    let stay = NSButton(checkboxWithTitle: "替换后停留", target: nil, action: nil)
    let confirmOpen = NSButton(checkboxWithTitle: "替换所有打开文档前确认", target: nil, action: nil)
    var queryHistory: [String] = []
    var replaceHistory: [String] = []
    var directoryHistory: [String] = []
    var filterHistory: [String] = []
    public private(set) var page: FindReplacePage = .find
    let tabs = NSSegmentedControl(
        labels: FindReplacePage.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    var directoryRow: NSGridRow?
    var filterRow: NSGridRow?
    let navigationOptions = NSStackView()
    let fileOptions = NSStackView()
    let navigationActions = NSStackView()
    let replacementActions = NSStackView()
    let fileActions = NSStackView()
    let markActions = NSStackView()
    public var stayAfterReplace: Bool {
        stay.state == .on
    }
    public var confirmsOpenReplacement: Bool {
        confirmOpen.state == .on
    }
    public var options: SearchOptions {
        var result = SearchOptions()
        result.query = query.stringValue
        result.replacement = replacement.stringValue
        result.mode = SearchMode.allCases[max(0, mode.indexOfSelectedItem)]
        result.caseSensitive = caseSensitive.state == .on
        result.wholeWord = wholeWord.state == .on
        result.dotMatchesNewline = dot.state == .on
        result.backwards = backwards.state == .on
        result.wrap = wrap.state == .on
        result.selectionOnly = selection.state == .on
        result.recursive = recursive.state == .on
        result.includeHidden = includeHidden.state == .on
        result.ignoreOpenBuffers = diskBuffers.state == .on
        return result
    }

    /// 业务作用：复验跨文件请求的完整输入，目录或过滤条件的变化也会撤销旧计划继续发布和写盘的权限。
    /// 参数说明:
    /// - options: 发起请求时的查找与替换条件。
    /// - directory: 原请求根目录的完整输入。
    /// - filters: 原请求的包含与排除模式。
    /// 返回：所有条件和路径、过滤原文完全相同时为真，不进行 Unicode 规范化或路径改写。
    public func matchesDirectoryRequest(
        options: SearchOptions,
        directory: String,
        filters: String
    ) -> Bool {
        self.options == options
            && self.directory.stringValue.utf8.elementsEqual(directory.utf8)
            && self.filters.stringValue.utf8.elementsEqual(filters.utf8)
    }

    /// 业务作用：创建可持续操作的非模态查找替换窗口，常用选项始终可见。
    /// 参数说明: 无。
    /// 返回：不阻断正文编辑的独立窗口。
    public init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 790, height: 490),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "查找与替换 — Nate"
        window.minSize = NSSize(width: 750, height: 400)
        window.setFrameAutosaveName("Nate.FindReplace")
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            ])
        }
        tabs.target = self
        tabs.action = #selector(pageChanged)
        root.addArrangedSubview(tabs)
        query.placeholderString = "查找内容（可粘贴换行、Tab 和 NUL）"
        replacement.placeholderString = "替换为（留空表示删除）"
        directory.placeholderString = "明确的搜索根目录"
        filters.placeholderString = "包含、排除及目录模式"
        filters.stringValue = "*.*"
        for input in [query, replacement, directory, filters] {
            input.delegate = self
            input.onFeedback = {
                [weak self] message in
                self?.feedback.stringValue = message
            }
        }
        query.onHistoryChange = {
            [weak self] values in
            self?.queryHistory = values
        }
        replacement.onHistoryChange = {
            [weak self] values in
            self?.replaceHistory = values
        }
        directory.onHistoryChange = {
            [weak self] values in
            self?.directoryHistory = values
        }
        filters.onHistoryChange = {
            [weak self] values in
            self?.filterHistory = values
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "查找内容"), query],
            [NSTextField(labelWithString: "替换为"), replacement],
            [NSTextField(labelWithString: "目录"), directory],
            [NSTextField(labelWithString: "过滤条件"), filters],
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        directoryRow = grid.row(at: 2)
        filterRow = grid.row(at: 3)
        root.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        query.widthAnchor.constraint(greaterThanOrEqualToConstant: 550).isActive = true
        mode.addItems(withTitles: SearchMode.allCases.map(\.rawValue))
        mode.target = self
        mode.action = #selector(modeChanged)
        wrap.state = .on
        confirmOpen.state = .on
        recursive.state = .on
        let options = NSStackView(views: [mode, caseSensitive, wholeWord, dot])
        options.spacing = 14
        root.addArrangedSubview(options)
        for option in [backwards, wrap, selection] {
            navigationOptions.addArrangedSubview(option)
        }
        root.addArrangedSubview(navigationOptions)
        root.addArrangedSubview(stay)
        root.addArrangedSubview(confirmOpen)
        for option in [recursive, includeHidden, diskBuffers] {
            fileOptions.addArrangedSubview(option)
        }
        root.addArrangedSubview(fileOptions)
        for (id, title) in [
            ("previous", "上一个"), ("next", "下一个"), ("count", "计数"),
            ("all", "当前文档全部查找"), ("open", "全部打开文档查找"),
        ] {
            navigationActions.addArrangedSubview(button(id, title))
        }
        for (id, title) in [
            ("replaceOne", "替换一个"), ("replaceAll", "当前文档全部替换"),
            ("replaceOpen", "全部打开文档替换"),
        ] {
            replacementActions.addArrangedSubview(button(id, title))
        }
        fileActions.addArrangedSubview(button("files", "文件中查找"))
        fileActions.addArrangedSubview(button("replaceFiles", "文件中替换"))
        markActions.addArrangedSubview(button("mark", "添加匹配行书签"))
        for actions in [navigationActions, replacementActions, fileActions, markActions] {
            actions.spacing = 5
            root.addArrangedSubview(actions)
        }
        let swap = NSButton(title: "交换查找与替换", target: self, action: #selector(swapInputs))
        swap.controlSize = .small
        root.addArrangedSubview(NSStackView(views: [button("cancel", "取消任务"), swap]))
        feedback.font = NSFont.systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        root.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        window.center()
        modeChanged()
        selectPage(.find, focus: false)
    }

    /// 业务作用：查找状态由应用管理，不从窗口归档恢复失效范围。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：从选区填入短查找表达式，超过阈值保留已有输入。
    /// 参数说明:
    /// - selection: 当前选区原文。
    /// - replacing: 是否显示替换交互。
    /// 返回：窗口可见并将焦点置于查找内容。
    public func present(selection: String?, replacing: Bool) {
        present(selection: selection, page: replacing ? .replace : .find)
    }

    /// 业务作用：打开指定的搜索范围页签，共享完整表达式、历史和模式，不在切换范围时清空输入。
    /// 参数说明:
    /// - selection: 可用于填充查找内容的完整短选区。
    /// - page: 菜单或快捷键请求的实际操作范围。
    /// 返回：对应页签可见，焦点进入查找内容；无目录时文件操作仍由执行入口明确拒绝。
    public func present(selection: String?, page: FindReplacePage) {
        if let selection, !selection.isEmpty, selection.count <= 1024 {
            query.stringValue = selection
        }
        selectPage(page, focus: false)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(query)
    }

    /// 业务作用：页签点击改变可见范围与对应动作，实际查找条件保持原值。
    /// 参数说明: 无。
    /// 返回：文件页显示目录和过滤，其它页显示适用的缓冲区操作。
    @objc func pageChanged() {
        guard FindReplacePage.allCases.indices.contains(tabs.selectedSegment) else {
            return
        }
        selectPage(FindReplacePage.allCases[tabs.selectedSegment], focus: true)
    }

    /// 业务作用：统一菜单和页签的范围展示，隐藏控件不清除选项，也不重新授予后台请求执行权。
    /// 参数说明:
    /// - page: 新的可见操作范围。
    /// - focus: 是否把键盘入口交给查找内容。
    /// 返回：可见动作与页签一致，查找、替换原文和目录输入保留。
    func selectPage(_ page: FindReplacePage, focus: Bool) {
        self.page = page
        tabs.selectedSegment = FindReplacePage.allCases.firstIndex(of: page) ?? 0
        let files = page == .files
        let replacing = page == .replace
        directoryRow?.isHidden = !files
        filterRow?.isHidden = !files
        navigationOptions.isHidden = files
        fileOptions.isHidden = !files
        stay.isHidden = !replacing
        confirmOpen.isHidden = !replacing
        navigationActions.isHidden = page != .find && !replacing
        replacementActions.isHidden = !replacing
        fileActions.isHidden = !files
        markActions.isHidden = page != .mark
        window?.title = page.rawValue + " — Nate"
        window?.contentView?.layoutSubtreeIfNeeded()
        if focus {
            window?.makeFirstResponder(query)
        }
    }

    /// 业务作用：交换完整查找和替换原文，长内容与不可见字符不经过显示摘要或历史标签。
    /// 参数说明: 无。
    /// 返回：两个完整输入互换；输入法仍有候选时保留原输入并提示先完成候选。
    @objc func swapInputs() {
        // 候选属于原生输入上下文，交换不能让程序化赋值提交或丢弃未确认的组合内容。
        guard (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else {
            feedback.stringValue = "请先确认或取消输入法候选，再交换查找与替换。"
            return
        }
        let originalQuery = query.stringValue
        let originalReplacement = replacement.stringValue
        query.stringValue = originalReplacement
        replacement.stringValue = originalQuery
    }

    /// 业务作用：独立按钮标识与公共命令回调保持一致。
    /// 参数说明:
    /// - id: 操作标识。
    /// - title: 用户可见范围说明。
    /// 返回：实际可执行的操作按钮。
    func button(_ id: String, _ title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        if id == "previous" {
            previousButton = button
        }
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    /// 业务作用：在正则模式禁用不兼容的全词及默认反向查找。
    /// 参数说明: 无。
    /// 返回：界面选项与执行语义一致。
    @objc func modeChanged() {
        let regex = mode.indexOfSelectedItem == 2
        wholeWord.isEnabled = !regex
        backwards.isEnabled = !regex
        previousButton?.isEnabled = !regex
        dot.isEnabled = regex
        if regex {
            wholeWord.state = .off
            backwards.state = .off
        }
    }

    /// 业务作用：记录完整历史并将操作提交给应用后台搜索协调。
    /// 参数说明:
    /// - sender: 具体动作按钮。
    /// 返回：实际命中、替换数或错误由固定反馈区域显示。
    @objc func performAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else {
            return
        }
        submit(id)
    }

    /// 业务作用：按钮和键盘使用同一请求入口，完整历史更新不改变实际执行文本，取消不增加历史。
    /// 参数说明:
    /// - id: 已确定方向和范围的动作标识。
    /// 返回：四类完整输入按最近使用顺序保留最多 30 项，再调用应用的后台协调入口。
    func submit(_ id: String) {
        if id != "cancel" {
            remember(query, history: &queryHistory)
            remember(replacement, history: &replaceHistory)
            if id == "files" || id == "replaceFiles" {
                remember(directory, history: &directoryHistory)
                remember(filters, history: &filterHistory)
            }
            feedback.stringValue =
                "正在执行… · 查找 \(query.stringValue.utf8.count) 字节，替换 \(replacement.stringValue.utf8.count) 字节"
        }
        onAction?(id, options, directory.stringValue, filters.stringValue)
    }

    /// 业务作用：以完整原文去重并重建单一输入的历史，显示短标签不参与历史身份比较。
    /// 参数说明:
    /// - input: 持有完整输入的控件。
    /// - history: 对应字段的最近使用历史。
    /// 返回：最近输入置顶，规范等价但字节不同的输入各自保留，超过 30 项移除最旧记录。
    func remember(_ input: SearchInputBox, history: inout [String]) {
        let value = input.stringValue
        history = Array(
            ([value]
                + history.filter {
                    !$0.utf8.elementsEqual(value.utf8)
                }).prefix(30)
        )
        input.removeAllItems()
        input.addItems(withObjectValues: history)
    }

    /// 业务作用：Enter 只执行方向查找，Esc 返回正文，候选确认由文本控件优先处理。
    /// 参数说明:
    /// - control: 当前输入框。
    /// - textView: 系统字段编辑器。
    /// - commandSelector: 原生键盘命令。
    /// 返回：已处理的命令为真，其他交给原生输入。
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        let name = NSStringFromSelector(commandSelector)
        if textView.hasMarkedText() {
            return false
        }
        if name == "cancelOperation:" {
            window?.orderOut(nil)
            onDismiss?()
            return true
        }
        if name == "insertNewline:" || name == "insertNewlineIgnoringFieldEditor:" {
            var previous = backwards.state == .on
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                previous.toggle()
            }
            submit(previous ? "previous" : "next")
            return true
        }
        return false
    }
}
