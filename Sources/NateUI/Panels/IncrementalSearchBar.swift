import AppKit
import NateSearch

@MainActor
public final class IncrementalSearchBar: NSView, NSTextFieldDelegate {
    public var onQuery: ((String, IncrementalSearchOptions) -> Void)?
    public var onNavigate: ((Bool) -> Void)?
    public var onClose: (() -> Void)?
    public var onOptionsChange: ((IncrementalSearchOptions) -> Void)?
    public var onHighlightChange: ((String, IncrementalSearchOptions) -> Void)?
    public var onSuspend: (() -> Bool)?
    public let input = SearchInputBox(frame: .zero)
    public let feedback = NSTextField(labelWithString: "")
    public let highlightFeedback = NSTextField(labelWithString: "")
    let caseSensitive = NSButton(
        checkboxWithTitle: "区分大小写",
        target: nil,
        action: nil
    )
    let wholeWord = NSButton(
        checkboxWithTitle: "全词",
        target: nil,
        action: nil
    )
    let wrap = NSButton(
        checkboxWithTitle: "循环",
        target: nil,
        action: nil
    )
    let highlightAll = NSButton(
        checkboxWithTitle: "全部高亮",
        target: nil,
        action: nil
    )
    public private(set) var query = ""
    var restoring = false
    var editing = false
    var needsRestart = false
    var feedbackBeforeEditing: String?
    public var isEditingInput: Bool {
        editing || input.isEditingInput
    }
    public var options: IncrementalSearchOptions {
        var options = IncrementalSearchOptions()
        options.caseSensitive = caseSensitive.state == .on
        options.wholeWord = wholeWord.state == .on
        options.wrap = wrap.state == .on
        options.highlightAll = highlightAll.state == .on
        return options
    }

    /// 业务作用：在编辑区上方提供已确认输入触发的字面查找、前后导航及独立选项。
    /// 参数说明:
    /// - frameRect: 主窗口提供的布局区域。
    /// 返回：非模态搜索栏具有独立定位与高亮状态，长输入仍使用完整原文编辑入口。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        input.placeholderString = "增量查找（普通字面模式）"
        input.delegate = self
        input.onCancel = {
            [weak self] in self?.onClose?()
        }
        input.onSubmit = {
            [weak self] previous in
            self?.publishQuery()
            self?.onNavigate?(previous)
        }
        input.onEditingStateChange = {
            [weak self] editing in
            guard let self else {
                return
            }
            self.editing = editing
            if editing {
                self.feedbackBeforeEditing = self.feedback.stringValue
                self.needsRestart = self.onSuspend?() == true || self.needsRestart
                self.feedback.stringValue = "正在编辑输入，确认后继续查找。"
            }
            else if !self.needsRestart {
                self.feedback.stringValue = self.feedbackBeforeEditing ?? self.feedback.stringValue
            }
            if !editing {
                self.feedbackBeforeEditing = nil
            }
        }
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        input.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        input.onCommittedChange = {
            [weak self] _ in self?.publishQuery()
        }
        input.onFeedback = {
            [weak self] message in self?.feedback.stringValue = message
        }
        let previous = NSButton(
            title: "上一处",
            target: self,
            action: #selector(previousMatch)
        )
        let next = NSButton(
            title: "下一处",
            target: self,
            action: #selector(nextMatch)
        )
        let close = NSButton(
            title: "关闭",
            target: self,
            action: #selector(closeBar)
        )
        let first = NSStackView(views: [NSTextField(labelWithString: "增量查找"), input, previous, next, close])
        first.spacing = 6
        wrap.state = .on
        for button in [caseSensitive, wholeWord, wrap, highlightAll] {
            button.target = self
            button.action = #selector(optionsChanged(_:))
        }
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let second = NSStackView(views: [caseSensitive, wholeWord, wrap, highlightAll, feedback])
        second.spacing = 12
        highlightFeedback.font = .systemFont(ofSize: 11)
        highlightFeedback.textColor = .secondaryLabelColor
        highlightFeedback.lineBreakMode = .byTruncatingTail
        highlightFeedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSStackView(views: [first, second, highlightFeedback])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            first.widthAnchor.constraint(equalTo: root.widthAnchor),
            second.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            highlightFeedback.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    /// 业务作用：增量栏由主窗口建立，不从归档恢复控件或旧请求。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：显示时恢复独立选项并可填入完整短选区，程序化装配只发布一次最终查询。
    /// 参数说明:
    /// - query: 可填入的新查询；为空时保留本次运行的既有输入。
    /// - options: 需要恢复的增量选项。
    /// 返回：当前输入与选项完整恢复，调用者随后显式开始查询。
    public func prepare(query: String?, options: IncrementalSearchOptions) {
        restoring = true
        if let query {
            input.stringValue = query
        }
        self.query = input.stringValue
        caseSensitive.state = options.caseSensitive ? .on : .off
        wholeWord.state = options.wholeWord ? .on : .off
        wrap.state = options.wrap ? .on : .off
        highlightAll.state = options.highlightAll ? .on : .off
        needsRestart = false
        restoring = false
    }

    /// 业务作用：只把已经确认且与上次发布不同的原文交给后台，输入法候选不会进入查询快照。
    /// 参数说明:
    /// - force: 显示栏或改变选项时允许复用同一查询原文重新执行。
    /// 返回：完整查询进入应用协调；组合输入、恢复过程及重复通知不启动额外任务。
    public func publishQuery(force: Bool = false) {
        // 未确认候选和程序化恢复都没有查询发布权，完整输入须先成为当前明确条件。
        guard !isHidden, !restoring, !isEditingInput else {
            return
        }
        let value = input.stringValue
        guard force || needsRestart || !query.utf8.elementsEqual(value.utf8) else {
            return
        }
        query = value
        needsRestart = false
        onQuery?(query, options)
    }

    /// 业务作用：后台完成先于候选通知时保留一次查询重试意图，未确认内容仍不取得正文导航权。
    /// 参数说明: 无。
    /// 返回：下次确认或取消候选回到完整原文后重新执行当前条件，光标暂不改变。
    public func deferQueryUntilConfirmed() {
        needsRestart = true
        feedback.stringValue = "正在编辑输入，确认后继续查找。"
    }

    /// 业务作用：匹配选项重新定位，仅切换全部高亮时只更新临时图层，不移动当前光标。
    /// 参数说明:
    /// - sender: 用户明确切换的选项控件。
    /// 返回：完整选项保存；高亮开关只通知图层，其余选项通过已确认查询入口重新执行。
    @objc func optionsChanged(_ sender: NSButton) {
        onOptionsChange?(options)
        if sender === highlightAll {
            onHighlightChange?(query, options)
        }
        else {
            publishQuery(force: true)
        }
    }

    /// 业务作用：请求从当前命中向前导航，候选确认仍由原生输入上下文处理。
    /// 参数说明: 无。
    /// 返回：无候选时提交上一个匹配意图。
    @objc func previousMatch() {
        // 导航按钮不能代替输入上下文提前确认候选。
        guard !isEditingInput else {
            return
        }
        publishQuery()
        onNavigate?(true)
    }

    /// 业务作用：请求从当前命中向后导航，不改变完整查询或查找窗口的条件。
    /// 参数说明: 无。
    /// 返回：无候选时提交下一个匹配意图。
    @objc func nextMatch() {
        // 只有完整已确认原文可以推动正文选择。
        guard !isEditingInput else {
            return
        }
        publishQuery()
        onNavigate?(false)
    }

    /// 业务作用：关闭增量栏交由应用撤销后台发布权并把焦点交回正文。
    /// 参数说明: 无。
    /// 返回：发出关闭意图，当前文本不改变。
    @objc func closeBar() {
        onClose?()
    }

    /// 业务作用：Enter 导航、Shift-Enter 反向，Esc 在候选处理后返回正文。
    /// 参数说明:
    /// - control: 当前查询字段。
    /// - textView: 原生字段编辑器。
    /// - commandSelector: 原生输入命令。
    /// 返回：已处理命令为真，其余保留原生输入语义。
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        // Enter 和 Esc 先属于候选窗口，增量栏不能截获这一步确认或取消。
        guard !textView.hasMarkedText() else {
            return false
        }
        switch NSStringFromSelector(commandSelector) {
        case "cancelOperation:":
            closeBar()
            return true
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
            publishQuery()
            onNavigate?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        default:
            return false
        }
    }
}
