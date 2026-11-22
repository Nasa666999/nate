import AppKit
import NateCore
import NateSyntax

private final class StructureItem: NSObject {
    let symbol: FunctionSymbol
    let children: [StructureItem]

    /// 业务作用：为原生树表保留稳定的行对象，展开与导航共享同一个结构快照。
    /// 参数说明:
    /// - symbol: 当前节点及其原始导航范围。
    /// - children: 已过滤和排序的子节点。
    /// 返回：不持有可变文档的展示节点。
    init(symbol: FunctionSymbol, children: [StructureItem]) {
        self.symbol = symbol
        self.children = children
    }
}

private final class StructureOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?

    /// 业务作用：保留系统树表方向键与输入行为，回车使用与双击一致的定位入口。
    /// 参数说明:
    /// - event: 原生按键事件。
    /// 返回：回车提交选中结构，其余按键交给树表。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
        }
        else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
public final class StructurePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate
{
    public var onNavigate: ((ByteRange) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onClose: (() -> Void)?
    let filter = NSSearchField()
    let order = NSSegmentedControl(
        labels: ["源码顺序", "名称排序"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let state = NSTextField(labelWithString: "")
    private let outline = StructureOutlineView()
    private var model: FunctionOutline?
    private var items: [StructureItem] = []
    private var detail = ""
    private var sortingDefaults = UserDefaults.standard

    /// 业务作用：结构排序跟随当前明确的配置来源，导入只排列已有结构，不重新读取正文或保存默认值。
    /// 参数说明:
    /// - defaults: 当前应用使用的完整偏好域。
    /// 返回：原筛选和结构模型保留，排序控件与已有结果采用当前偏好。
    public func loadSortingPreferences(from defaults: UserDefaults) {
        sortingDefaults = defaults
        order.selectedSegment = defaults.bool(forKey: "structure.sortByName") ? 1 : 0
        rebuild()
    }

    /// 业务作用：组装可过滤、排序和键盘定位的结构侧栏，不在视图内运行文件或正则任务。
    /// 参数说明:
    /// - frameRect: 初始侧栏区域。
    /// 返回：仅发送导航、刷新与关闭意图的原生面板。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "函数列表")
        title.font = .boldSystemFont(ofSize: 12)
        let refresh = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新函数列表")
                ?? NSImage(),
            target: self,
            action: #selector(refreshAction)
        )
        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭函数列表") ?? NSImage(),
            target: self,
            action: #selector(closeAction)
        )
        refresh.bezelStyle = .inline
        close.bezelStyle = .inline
        let heading = NSStackView(views: [title, NSView(), refresh, close])
        heading.orientation = .horizontal
        heading.spacing = 6
        filter.placeholderString = "筛选名称"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel("函数列表名称筛选")
        order.selectedSegment = UserDefaults.standard.bool(forKey: "structure.sortByName") ? 1 : 0
        order.target = self
        order.action = #selector(orderChanged)
        order.controlSize = .small
        order.segmentDistribution = .fillEqually
        order.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateSelection)
        outline.allowsEmptySelection = true
        outline.setAccessibilityLabel("函数与类结构")
        outline.onActivate = {
            [weak self] in self?.activateSelection()
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        state.font = .systemFont(ofSize: 10)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        state.maximumNumberOfLines = 2
        for view in [heading, filter, order, scroll, state] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filter.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            order.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            order.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            order.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: order.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -4),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            state.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            state.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// 业务作用：结构面板由工作区显式装配，不从未验证归档恢复任务状态。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：规则或文档变化时立即撤销旧导航证据，再显示后台任务状态。
    /// 参数说明:
    /// - message: 等待、无规则或失败原因。
    /// 返回：旧列表不可再定位新正文。
    public func showState(_ message: String) {
        model = nil
        items = []
        outline.reloadData()
        state.stringValue = message
        state.toolTip = message
    }

    /// 业务作用：接收应用已复验的结构快照，过滤与排序只改变展示顺序。
    /// 参数说明:
    /// - result: 当前文档的完整结构。
    /// - detail: 语言或资源说明。
    /// 返回：树表按现有筛选条件更新，不改变编辑焦点。
    public func update(_ result: FunctionOutline, detail: String) {
        model = result
        self.detail = detail
        rebuild()
    }

    /// 业务作用：筛选和排序复用已发布模型，父类名称命中时保留其全部方法。
    /// 参数说明: 无。
    /// 返回：可展开的当前结果树，正文与后台任务不受影响。
    private func rebuild() {
        guard model != nil else {
            return
        }
        let query = filter.stringValue
        items = makeItems(model?.symbols ?? [], query: query, inherited: false)
        let message = items.isEmpty ? (query.isEmpty ? "没有找到适用结构。" : "筛选后没有匹配。") : detail
        state.stringValue = message
        state.toolTip = message
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    /// 业务作用：递归构建过滤后的可见节点，方法命中时保留所属类以展示上下文。
    /// 参数说明:
    /// - symbols: 当前层原始节点。
    /// - query: 名称筛选文本。
    /// - inherited: 父级已命中，子节点无需再次过滤。
    /// 返回：保留源码顺序或按用户选择排序的节点。
    private func makeItems(_ symbols: [FunctionSymbol], query: String, inherited: Bool) -> [StructureItem] {
        var result: [StructureItem] = []
        for symbol in symbols {
            let matches = inherited || query.isEmpty || symbol.name.localizedCaseInsensitiveContains(query)
            let children = makeItems(symbol.children, query: query, inherited: matches)
            if matches || !children.isEmpty {
                result.append(StructureItem(symbol: symbol, children: children))
            }
        }
        if order.selectedSegment == 1 {
            result.sort {
                $0.symbol.name.localizedStandardCompare($1.symbol.name) == .orderedAscending
            }
        }
        return result
    }

    /// 业务作用：名称输入只过滤本地模型，避免每个筛选字符重复解析全文。
    /// 参数说明:
    /// - obj: 原生搜索框变更通知。
    /// 返回：当前列表立即反映筛选条件。
    public func controlTextDidChange(_ obj: Notification) {
        rebuild()
    }

    /// 业务作用：保存结构排序偏好并重新排列现有结果。
    /// 参数说明: 无。
    /// 返回：后续打开面板沿用同一顺序。
    @objc private func orderChanged() {
        sortingDefaults.set(order.selectedSegment == 1, forKey: "structure.sortByName")
        rebuild()
    }

    /// 业务作用：刷新意图交回应用，重新核验文档与资源身份。
    /// 参数说明: 无。
    /// 返回：发出一次显式刷新请求。
    @objc private func refreshAction() {
        onRefresh?()
    }

    /// 业务作用：关闭侧栏只结束结构任务，不关闭任何文档。
    /// 参数说明: 无。
    /// 返回：交回应用处理可见性和取消。
    @objc private func closeAction() {
        onClose?()
    }

    /// 业务作用：双击或回车使用同一快照范围发出定位请求，最终修订复验由应用负责。
    /// 参数说明: 无。
    /// 返回：有有效选中节点时发出一次导航意图。
    @objc private func activateSelection() {
        guard model != nil, outline.selectedRow >= 0,
            let item = outline.item(atRow: outline.selectedRow) as? StructureItem
        else {
            return
        }
        onNavigate?(item.symbol.range)
    }

    /// 业务作用：原生树表从当前可见层获取节点数，不重新解析正文。
    /// 参数说明:
    /// - outlineView: 当前树表。
    /// - item: 父节点，空值表示根。
    /// 返回：该层可见节点数量。
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? StructureItem)?.children.count ?? items.count
    }

    /// 业务作用：将树表行索引解析为当前模型中的节点对象。
    /// 参数说明:
    /// - outlineView: 当前树表。
    /// - index: 该父级下的子节点序号。
    /// - item: 父节点，空值表示根。
    /// 返回：树表已请求的有效子节点。
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? StructureItem)?.children ?? items)[index]
    }

    /// 业务作用：只为实际具有可见子项的类显示展开标记。
    /// 参数说明:
    /// - outlineView: 当前树表。
    /// - item: 待展示节点。
    /// 返回：当前节点是否可以展开。
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? StructureItem)?.children.isEmpty ?? true)
    }

    /// 业务作用：复用原生单元格展示类与函数，完整名称保留在悬停说明中。
    /// 参数说明:
    /// - outlineView: 当前树表。
    /// - tableColumn: 当前名称列。
    /// - item: 对应结构节点。
    /// 返回：带语义图标和名称的单元格。
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let item = item as? StructureItem else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("structure.name")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = (item.symbol.isContainer ? "▱ " : "ƒ ") + item.symbol.name
        cell.toolTip = item.symbol.name
        return cell
    }
}
