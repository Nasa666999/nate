import AppKit
import NateCore
import NateSearch

@MainActor
public final class EditorWindow: NSWindowController, NSWindowDelegate {
    public var onCommand: ((String) -> Void)?
    public var onSelect: ((UUID) -> Void)?
    public var onCloseTab: ((UUID) -> Void)?
    public var onTabAction: ((UUID, String) -> Void)?
    public var onTabReorder: ((DocumentOrderMove) -> Bool)?
    /// 业务作用：工作区发布重排时复验实际标签栏的原顺序代次，顺序往返不能恢复旧手势资格。
    /// 参数说明: 无。
    /// 返回：当前标签栏持有的顺序控制身份，不授予正文修改权。
    public var tabOrderIdentity: UUID {
        tabs.orderIdentity
    }
    public var onEdit: (() -> Void)?
    public var onTextInput: ((String) -> Void)?
    public var onPairInput: ((PairInputCommand) -> Void)?
    public var onEditorCommand: ((EditorCommand) -> Void)?
    public var onClipboardCapture: ((ClipboardPayload) -> Void)?
    public var onClipboardPaste: ((ClipboardPayload, Bool) -> Void)?
    public var onClipboardCopy: ((Bool, Bool) -> Void)?
    public var onWindowClose: (() -> Void)?
    public var onIncrementalQuery: ((String, IncrementalSearchOptions) -> Void)?
    public var onIncrementalOptions: ((IncrementalSearchOptions) -> Void)?
    public var onIncrementalSuspend: (() -> Bool)?
    public var selectedTextHighlightSettings: ((EditorView) -> SelectedTextHighlightSettings?)?
    public let incrementalSearch = IncrementalSearchBar(frame: .zero)
    public let directoryPanel = DirectoryTreePanel(frame: .zero)
    public let projectPanels = ProjectPanelsView(frame: .zero)
    let navigationSplit = NSSplitView()
    var incrementalHeight: NSLayoutConstraint?
    public internal(set) var editor: EditorView
    public let status = SaveStatusField(labelWithString: "")
    let results = ResultTextView()
    public var onOpenURLs: (([URL]) -> Void)?
    public var onResult: ((Int) -> Void)?
    public internal(set) var resultGeneration = UUID()
    public let searchResults = SearchResultsPanel(frame: .zero)
    let resultHost = NSView()
    let tabs = TabStrip()
    weak var tabLayoutRoot: NSView?
    var tabHeight: NSLayoutConstraint?
    var tabLayoutConstraints: [NSLayoutConstraint] = []
    let scroll = NSScrollView()
    let split = NSSplitView()
    let editorSplit = NSSplitView()
    let workspaceSplit = NSSplitView()
    public let structurePanel = StructurePanel(frame: .zero)
    public var isStructureVisible: Bool {
        !structurePanel.isHidden
    }
    let resultsScroll = NSScrollView()
    let toolbarStack = NSStackView()
    var scrollPositions: [UUID: NSPoint] = [:]

    /// 业务作用：组装工具栏、独立标签、编辑视口、结果面板和状态栏。
    /// 参数说明:
    /// - document: 初始文档。
    /// 返回：可直接输入的原生主窗口。
    public init(document: DocumentBuffer) {
        editor = EditorView(document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nate"
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Nate.MainWindow")
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        for (id, symbol, name) in [
            ("new", "doc.badge.plus", "新建 ⌘N"), ("open", "folder", "打开 ⌘O"),
            ("save", "square.and.arrow.down", "立即保存 ⌘S"),
            ("saveAll", "square.and.arrow.down.on.square", "全部保存 ⌘⌥S"),
            ("undo", "arrow.uturn.backward", "撤销 ⌘Z"), ("redo", "arrow.uturn.forward", "重做 ⌘⇧Z"),
            ("find", "magnifyingglass", "查找 ⌘F / Ctrl+F"), ("replace", "arrow.left.arrow.right", "替换 Ctrl+H"),
            ("wrap", "text.word.spacing", "自动换行"), ("symbols", "paragraphsign", "显示符号"),
            ("recordMacro", "record.circle", "录制宏"), ("playMacro", "play", "播放宏"),
            ("documentList", "list.bullet", "文档列表"),
        ] {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(),
                target: self,
                action: #selector(toolbarAction(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.toolTip = name
            button.bezelStyle = .texturedRounded
            toolbarStack.addArrangedSubview(button)
        }
        toolbarStack.addArrangedSubview(NSView())
        root.addSubview(toolbarStack)
        root.addSubview(tabs)
        root.addSubview(incrementalSearch)
        incrementalSearch.isHidden = true
        incrementalSearch.onQuery = {
            [weak self] query, options in self?.onIncrementalQuery?(query, options)
        }
        incrementalSearch.onOptionsChange = {
            [weak self] options in self?.onIncrementalOptions?(options)
        }
        incrementalSearch.onSuspend = {
            [weak self] in self?.onIncrementalSuspend?() ?? false
        }
        incrementalSearch.onNavigate = {
            [weak self] previous in self?.onCommand?(previous ? "incrementalPrevious" : "incrementalNext")
        }
        incrementalSearch.onClose = {
            [weak self] in self?.onCommand?("closeIncrementalSearch")
        }
        tabs.onSelect = {
            [weak self] id in self?.onSelect?(id)
        }
        tabs.onClose = {
            [weak self] id in self?.onCloseTab?(id)
        }
        tabs.onAction = {
            [weak self] id, action in self?.onTabAction?(id, action)
        }
        tabs.onReorder = {
            [weak self] move in self?.onTabReorder?(move) ?? false
        }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = editor
        split.isVertical = false
        split.dividerStyle = .thin
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.addArrangedSubview(scroll)
        workspaceSplit.isVertical = true
        workspaceSplit.dividerStyle = .thin
        navigationSplit.isVertical = false
        navigationSplit.dividerStyle = .thin
        navigationSplit.addArrangedSubview(directoryPanel)
        navigationSplit.addArrangedSubview(projectPanels)
        navigationSplit.isHidden = true
        projectPanels.isHidden = true
        workspaceSplit.addArrangedSubview(navigationSplit)
        workspaceSplit.addArrangedSubview(editorSplit)
        workspaceSplit.addArrangedSubview(structurePanel)
        // 尺寸保持优先级低于系统拖动约束，侧栏才能保留初始宽度并允许用户调整。
        workspaceSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        workspaceSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)
        directoryPanel.isHidden = true
        structurePanel.isHidden = true
        structurePanel.onRefresh = {
            [weak self] in self?.onCommand?("refreshStructure")
        }
        structurePanel.onClose = {
            [weak self] in self?.onCommand?("closeStructure")
        }
        split.addArrangedSubview(workspaceSplit)
        results.isEditable = false
        results.onActivate = {
            [weak self] row in self?.onResult?(row)
        }
        editor.onOpenURLs = {
            [weak self] urls in self?.onOpenURLs?(urls)
        }
        results.isSelectable = true
        results.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        resultsScroll.hasVerticalScroller = true
        resultsScroll.documentView = results
        resultsScroll.isHidden = true
        searchResults.isHidden = true
        for view in [resultsScroll, searchResults] {
            view.translatesAutoresizingMaskIntoConstraints = false
            resultHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: resultHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: resultHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: resultHost.bottomAnchor),
            ])
        }
        searchResults.onPresentationChange = {
            [weak self] in self?.resultGeneration = UUID()
        }
        searchResults.onClose = {
            [weak self] in self?.setResultsVisible(false)
        }
        resultHost.isHidden = true
        split.addArrangedSubview(resultHost)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        root.addSubview(split)
        status.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.toolTip = "单击处理保存状态、重试或外部冲突。"
        status.onActivate = {
            [weak self] in self?.onCommand?("resolveSaveState")
        }
        status.lineBreakMode = .byTruncatingMiddle
        root.addSubview(status)
        status.heightAnchor.constraint(equalToConstant: 25).isActive = true
        for view in [toolbarStack, tabs, incrementalSearch, split, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        incrementalHeight = incrementalSearch.heightAnchor.constraint(equalToConstant: 0)
        incrementalHeight?.isActive = true
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarStack.heightAnchor.constraint(equalToConstant: 38),
            tabs.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
            incrementalSearch.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: incrementalSearch.bottomAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        configureTabLayout(in: root)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        editor.onChange = {
            [weak self] in self?.onEdit?()
        }
        editor.onTextInput = {
            [weak self] in self?.onTextInput?($0)
        }
        editor.onPairInput = {
            [weak self] in self?.onPairInput?($0)
        }
        editor.onEditorCommand = {
            [weak self] in self?.onEditorCommand?($0)
        }
        editor.onClipboardCapture = {
            [weak self] in self?.onClipboardCapture?($0)
        }
        editor.onClipboardPaste = {
            [weak self] in self?.onClipboardPaste?($0, $1)
        }
        editor.onClipboardCopy = {
            [weak self] in self?.onClipboardCopy?($0, $1)
        }
        editor.onSelection = {
            [weak self] in self?.onCommand?("selectionChanged")
        }
        editor.onCommand = {
            [weak self] id in self?.onCommand?(id)
        }
        editor.onStatus = {
            [weak self] message in self?.status.stringValue = message
        }
        let primary = editor
        primary.selectedTextHighlightContext = {
            [weak self, weak primary] in
            guard let self, let primary else {
                return nil
            }
            return self.selectedTextContext(for: primary)
        }
        editor.onFocus = {
            [weak self, weak primary] in
            guard let self, let primary else {
                return
            }
            self.editor = primary
            self.onCommand?("selectionChanged")
        }
        window.center()
        editor.refresh()
    }

    /// 业务作用：窗口不使用归档创建，工作区拥有唯一文档集合。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：切换标签时保留各文档视口，避免后台更新抢焦点。
    /// 参数说明:
    /// - document: 新活动文档。
    /// 返回：确认原候选后切换并保存视口时为真；候选失败时保持原文档与视图并为假。
    @discardableResult
    public func showDocument(_ document: DocumentBuffer) -> Bool {
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard editor.finishComposition() else {
            return false
        }
        let container = editor.enclosingScrollView ?? scroll
        scrollPositions[editor.document.id] = container.contentView.bounds.origin
        editor.document = document
        editor.refresh()
        container.contentView.scroll(to: scrollPositions[document.id] ?? .zero)
        window?.makeFirstResponder(editor)
        return true
    }

    /// 业务作用：共享正文的每个视图独立映射光标并重绘，后台视图不抢走焦点。
    /// 参数说明: 无。
    /// 返回：所有可见编辑视图反映各自文档的最新修订。
    public func refreshEditors() {
        for container in editorSplit.arrangedSubviews {
            ((container as? NSScrollView)?.documentView as? EditorView)?.refresh()
        }
    }

    /// 业务作用：更新标签呈现，标签上下文动作始终绑定被点击身份。
    /// 参数说明:
    /// - presentations: 按工作区顺序排列的标签。
    /// 返回：当前标签栏反映真实文档状态。
    public func updateTabs(_ presentations: [TabPresentation]) {
        tabs.update(presentations)
    }

    /// 业务作用：更新独立工具输出，正在操作搜索树时保留当前交互，不借后台输出结束筛选或抢走焦点。
    /// 参数说明:
    /// - text: 完整可读结果。
    /// - navigable: 是否存在与每行对应的有效定位证据。
    /// 返回：完整工具输出保留；未在结果树中交互时显示工具输出，否则保留当前结果视图。
    public func showResults(_ text: String, navigable: Bool = false) {
        resultGeneration = UUID()
        results.navigationEnabled = navigable
        results.string = text
        if searchResults.isHidden
            || (!searchResults.isEditingInput && !resultContainsResponder(searchResults))
        {
            resultsScroll.isHidden = false
            searchResults.isHidden = true
        }
        revealResultArea()
    }

    /// 业务作用：侧栏与克隆编辑区分别占用独立分隔区域，关闭侧栏不改变共享正文关系。
    /// 参数说明:
    /// - visible: 是否展示函数列表。
    /// 返回：显示时分配可调整宽度，编辑视图按实际剩余空间重新排版。
    public func setStructureVisible(_ visible: Bool) {
        structurePanel.isHidden = !visible
        window?.contentView?.layoutSubtreeIfNeeded()
        workspaceSplit.adjustSubviews()
        if visible {
            workspaceSplit.setPosition(max(280, workspaceSplit.bounds.width - 280), ofDividerAt: 1)
        }
        refreshEditors()
    }

    /// 业务作用：将工具栏入口交给同一命令路由。
    /// 参数说明:
    /// - sender: 具有命令标识的按钮。
    /// 返回：发出业务意图。
    @objc func toolbarAction(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue {
            onCommand?(id)
        }
    }

    /// 业务作用：关闭主窗口前交由应用异步保护最后修订。
    /// 参数说明:
    /// - sender: 请求关闭的窗口。
    /// 返回：阻止立即销毁，保存完成后由应用确认关闭。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        onWindowClose?()
        return false
    }

    /// 业务作用：窗口与分屏尺寸变化后，只重建各自的视口排版缓存。
    /// 参数说明:
    /// - notification: 系统窗口尺寸变化通知。
    /// 返回：软换行跟随实际可用宽度，正文与光标不被改写。
    public func windowDidResize(_ notification: Notification) {
        for container in editorSplit.arrangedSubviews {
            ((container as? NSScrollView)?.documentView as? EditorView)?.refresh()
        }
    }
}
