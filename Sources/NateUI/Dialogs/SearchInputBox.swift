import AppKit

@MainActor
public final class SearchInputBox: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let edit = NSButton(title: "编辑全文", target: nil, action: nil)
    private let history = NSPopUpButton(frame: .zero, pullsDown: true)
    private var values: [String] = []
    private var raw = ""
    private var inputGeneration = UUID()
    private var editor: SearchExpressionEditor?
    public weak var delegate: (any NSTextFieldDelegate)?
    public var onFeedback: ((String) -> Void)?
    public var placeholderString: String? {
        get {
            field.placeholderString
        }
        set {
            field.placeholderString = newValue
        }
    }
    public var stringValue: String {
        get {
            raw
        }
        set {
            // 程序化切换先结束旧字段提交，之后才设置新原文，不能让旧编辑回调覆盖新值。
            if field.currentEditor() != nil {
                window?.makeFirstResponder(edit)
            }
            raw = newValue
            inputGeneration = UUID()
            updatePresentation()
        }
    }

    /// 业务作用：搜索输入尺寸由窗口约束决定，不按完整表达式测量固有宽高。
    /// 参数说明: 无。
    /// 返回：固定的单行输入区域。
    public override var intrinsicContentSize: NSSize {
        NSSize(width: 550, height: 28)
    }

    /// 业务作用：允许查找窗口把键盘焦点交给输入组件，由组件选择短输入或全文编辑入口。
    /// 参数说明: 无。
    /// 返回：组件可成为首个响应者。
    public override var acceptsFirstResponder: Bool {
        true
    }

    /// 业务作用：把完整表达式存储、短输入、全文编辑和历史选择分开，长内容不进入原生单行控件的布局。
    /// 参数说明:
    /// - frameRect: 搜索窗口提供的初始布局区域。
    /// 返回：始终保留完整原文的搜索输入组件。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.delegate = self
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        edit.target = self
        edit.action = #selector(editFullText)
        edit.controlSize = .small
        history.controlSize = .small
        let row = NSStackView(views: [field, edit, history])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
        removeAllItems()
    }

    /// 业务作用：搜索输入由窗口创建，不从归档恢复已经失效的查询状态。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    public required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：清除历史菜单而保留当前完整输入，重新记录历史不能改变执行条件。
    /// 参数说明: 无。
    /// 返回：空历史列表，当前表达式不变。
    public func removeAllItems() {
        values.removeAll()
        history.removeAllItems()
        history.addItem(withTitle: "历史")
    }

    /// 业务作用：为完整历史建立有界可见标签，弹出菜单不测量大段表达式。
    /// 参数说明:
    /// - items: 按最近使用顺序排列的完整原文。
    /// 返回：每项只展示短标签，选择后仍使用完整历史值。
    public func addItems(withObjectValues items: [String]) {
        for value in items {
            let index = values.count
            values.append(value)
            var prefix = ""
            for scalar in value.unicodeScalars {
                guard prefix.utf8.count + scalar.utf8.count <= 180 else {
                    break
                }
                prefix.unicodeScalars.append(scalar)
            }
            let sample =
                prefix
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\0", with: "\\0")
            let title = sample + (prefix.utf8.count < value.utf8.count ? "…" : "")
            history.addItem(withTitle: title.isEmpty ? "（空输入）" : title)
            let item = history.lastItem
            item?.target = self
            item?.action = #selector(selectHistory(_:))
            item?.tag = index
        }
    }

    /// 业务作用：把搜索窗口的键盘焦点交给短输入，完整表达式在全文编辑窗口中输入。
    /// 参数说明: 无。
    /// 返回：原生字段接受焦点；长输入时打开其完整编辑窗口。
    public override func becomeFirstResponder() -> Bool {
        if field.isEditable {
            return window?.makeFirstResponder(field) == true
        }
        editFullText()
        return true
    }

    /// 业务作用：原生输入通知先固定全部原文，再切换长表达式展示，不能让布局摘要代替执行值。
    /// 参数说明:
    /// - notification: 当前短字段的文本变更。
    /// 返回：完整内容保留，长内容转入明确的全文编辑入口。
    public func controlTextDidChange(_ notification: Notification) {
        inputGeneration = UUID()
        guard let text = field.currentEditor() as? NSTextView else {
            raw = field.stringValue
            return
        }
        raw = text.string
        // 输入法候选仍由原生字段持有，普通变更不重写控件或结束候选；确认后才切换长输入展示。
        guard requiresFullEditor, !text.hasMarkedText() else {
            return
        }
        window?.makeFirstResponder(edit)
        updatePresentation()
    }

    /// 业务作用：短输入结束时固定已确认的完整内容，再切换长表达式的有界展示。
    /// 参数说明:
    /// - notification: 原生字段完成编辑的通知。
    /// 返回：后续执行读取完整原文，候选不会被摘要刷新抢先结束。
    public func controlTextDidEndEditing(_ notification: Notification) {
        raw = field.stringValue
        inputGeneration = UUID()
        updatePresentation()
    }

    /// 业务作用：把 Enter、Esc 与输入法候选的处理交回搜索窗口，输入组件不改变搜索方向。
    /// 参数说明:
    /// - control: 当前短输入字段。
    /// - textView: 原生字段编辑器。
    /// - commandSelector: 系统键盘命令。
    /// 返回：搜索窗口实际处理命令时为真，其余保留原生输入语义。
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        delegate?.control?(control, textView: textView, doCommandBy: commandSelector) ?? false
    }

    private var requiresFullEditor: Bool {
        raw.utf8.count > 2048 || raw.contains("\n") || raw.contains("\r") || raw.contains("\0")
    }

    /// 业务作用：只把有界短文本交给原生单行布局，完整表达式的摘要明确标示真实字节数。
    /// 参数说明: 无。
    /// 返回：显示和编辑入口与当前完整原文一致，不截断实际执行内容。
    private func updatePresentation() {
        let full = requiresFullEditor
        field.isEditable = !full
        field.stringValue = full ? "完整输入 · \(raw.utf8.count) 字节 · 请使用“编辑全文”" : raw
        field.toolTip = full ? "完整表达式已保留，点击“编辑全文”查看或修改。" : nil
    }

    /// 业务作用：选择历史时恢复完整表达式，短菜单标签不能成为查询原文。
    /// 参数说明:
    /// - sender: 携带完整历史索引的菜单项。
    /// 返回：当前完整输入切换到选定历史。
    @objc private func selectHistory(_ sender: NSMenuItem) {
        guard values.indices.contains(sender.tag) else {
            return
        }
        stringValue = values[sender.tag]
    }

    /// 业务作用：用有固定视口的多行编辑器处理完整输入，取消保留原值，确认后才发布新表达式。
    /// 参数说明: 无。
    /// 返回：复用当前全文编辑窗口，或显示绑定此输入的新窗口。
    @objc private func editFullText() {
        if let editor {
            editor.showWindow(nil)
            return
        }
        // 显式进入全文编辑先提交短字段，再固定草稿权威，附属窗口的焦点切换不能使自己的草稿过期。
        if field.currentEditor() != nil {
            window?.makeFirstResponder(edit)
        }
        let controller = SearchExpressionEditor(value: raw)
        let generation = inputGeneration
        controller.onComplete = {
            [weak self] value in
            guard let self else {
                return
            }
            // 查找窗口可能被新选区或历史重新赋值，旧草稿不能覆盖更新的完整输入。
            guard value == nil || self.inputGeneration == generation else {
                self.editor = nil
                self.onFeedback?("原输入已改变，旧草稿未发布；请重新打开“编辑全文”。")
                return
            }
            if let value {
                self.stringValue = value
            }
            self.editor = nil
        }
        editor = controller
        controller.present(attachedTo: window)
    }
}
