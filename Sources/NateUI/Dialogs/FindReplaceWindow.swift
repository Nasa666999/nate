import AppKit
import NateSearch

@MainActor
public final class FindReplaceWindow: NSWindowController, NSTextFieldDelegate {
    public var onAction: ((String, SearchOptions, String, String) -> Void)?
    public var onDismiss: (() -> Void)?
    public let feedback = NSTextField(wrappingLabelWithString: "输入查找内容。普通模式按字面查找，扩展模式解释反斜杠转义。")
    let query = SearchInputBox(frame: .zero)
    let replacement = SearchInputBox(frame: .zero)
    let directory = NSTextField()
    let filters = NSTextField(string: "*.*")
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
        let tabs = NSSegmentedControl(
            labels: ["查找", "替换", "文件中查找", "标记"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        tabs.selectedSegment = 1
        root.addArrangedSubview(tabs)
        query.placeholderString = "查找内容（可粘贴换行、Tab 和 NUL）"
        replacement.placeholderString = "替换为（留空表示删除）"
        query.delegate = self
        replacement.delegate = self
        for input in [query, replacement] {
            input.onFeedback = {
                [weak self] message in
                self?.feedback.stringValue = message
            }
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "查找内容"), query],
            [NSTextField(labelWithString: "替换为"), replacement],
            [NSTextField(labelWithString: "目录"), directory],
            [NSTextField(labelWithString: "过滤条件"), filters],
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 12
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
        root.addArrangedSubview(NSStackView(views: [backwards, wrap, selection, stay]))
        root.addArrangedSubview(confirmOpen)
        root.addArrangedSubview(NSStackView(views: [recursive, includeHidden, diskBuffers]))
        let row1 = NSStackView()
        let row2 = NSStackView()
        for (id, title) in [
            ("previous", "上一个"), ("next", "下一个"), ("count", "计数"),
            ("all", "当前文档全部查找"), ("open", "全部打开文档查找"), ("mark", "标记与书签"),
        ] {
            row1.addArrangedSubview(button(id, title))
        }
        for (id, title) in [
            ("replaceOne", "替换一个"), ("replaceAll", "当前文档全部替换"),
            ("replaceOpen", "全部打开文档替换"), ("files", "文件中查找"), ("replaceFiles", "文件中替换"), ("cancel", "取消任务"),
        ] {
            row2.addArrangedSubview(button(id, title))
        }
        row1.spacing = 5
        row2.spacing = 5
        root.addArrangedSubview(row1)
        root.addArrangedSubview(row2)
        feedback.font = NSFont.systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        root.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        window.center()
        modeChanged()
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
        if let selection, !selection.isEmpty, selection.count <= 1024 {
            query.stringValue = selection
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(query)
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
        queryHistory = Array(
            ([query.stringValue]
                + queryHistory.filter {
                    !$0.utf8.elementsEqual(query.stringValue.utf8)
                }).prefix(30)
        )
        replaceHistory = Array(
            ([replacement.stringValue]
                + replaceHistory.filter {
                    !$0.utf8.elementsEqual(replacement.stringValue.utf8)
                }).prefix(30)
        )
        query.removeAllItems()
        query.addItems(withObjectValues: queryHistory)
        replacement.removeAllItems()
        replacement.addItems(withObjectValues: replaceHistory)
        feedback.stringValue =
            "正在执行… · 查找 \(query.stringValue.utf8.count) 字节，替换 \(replacement.stringValue.utf8.count) 字节"
        onAction?(id, options, directory.stringValue, filters.stringValue)
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
            onAction?(previous ? "previous" : "next", options, directory.stringValue, filters.stringValue)
            return true
        }
        return false
    }
}
