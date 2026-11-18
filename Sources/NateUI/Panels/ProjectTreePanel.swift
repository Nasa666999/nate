import AppKit

public struct ProjectTreeEntry: Sendable {
    public let id: UUID
    public let parent: UUID?
    public let name: String
    public let pathHint: String?

    /// 业务作用：把虚拟定义转换为纯展示值，路径只供显示，不由视图探测或打开。
    /// 参数说明:
    /// - id: 稳定虚拟节点身份。
    /// - parent: 父节点身份，项目根为空。
    /// - name: 完整原始显示名称。
    /// - pathHint: 文件引用的原始路径，项目和分组为空。
    /// 返回：不含文件访问权限或正文引用的展示值。
    public init(id: UUID, parent: UUID?, name: String, pathHint: String?) {
        self.id = id
        self.parent = parent
        self.name = name
        self.pathHint = pathHint
    }
}

final class ProjectTreeItem: NSObject {
    var value: ProjectTreeEntry
    var children: [ProjectTreeItem] = []

    /// 业务作用：项目树复用稳定行对象，保存或改名后的刷新不把旧行号当成另一文件。
    /// 参数说明:
    /// - value: 当前节点展示定义。
    /// 返回：没有后代的稳定行对象。
    init(_ value: ProjectTreeEntry) {
        self.value = value
    }
}

struct ProjectMenuTarget {
    let generation: UUID
    let node: UUID?
}

final class ProjectOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?

    /// 业务作用：回车与双击共用文件打开或虚拟分组展开入口。
    /// 参数说明:
    /// - event: 当前原生按键。
    /// 返回：回车发送激活意图，其余保持系统树表导航。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
        }
        else {
            super.keyDown(with: event)
        }
    }

    /// 业务作用：右键菜单固定被点击的稳定节点，不能误用此前选中的另一行。
    /// 参数说明:
    /// - event: 当前原生右键事件。
    /// 返回：绑定点击行的当前菜单；空白区域仅提供工作区动作。
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onContextMenu?(row)
    }
}

@MainActor
public final class ProjectTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuItemValidation
{
    public var onAction: ((String, UUID?) -> Void)?
    public var onOpen: ((UUID) -> Void)?
    let outline = ProjectOutlineView()
    let title = NSTextField(labelWithString: "尚未载入工作区")
    let state = NSTextField(labelWithString: "新建或载入虚拟项目工作区。")
    let commands = NSPopUpButton(frame: .zero, pullsDown: true)
    var generation = UUID()
    var loaded = false
    var boundToFile = false
    var busy = false
    var roots: [ProjectTreeItem] = []
    var items: [UUID: ProjectTreeItem] = [:]

    public var selectedNode: UUID? {
        (outline.item(atRow: outline.selectedRow) as? ProjectTreeItem)?.value.id
    }

    /// 业务作用：以稳定节点身份捕获展开状态，侧栏恢复不依赖容易变化的原生行号。
    /// 参数说明: 无。
    /// 返回：按身份排序的当前展开分组，不读取任何文件引用。
    public var expandedNodes: [UUID] {
        items.values.filter {
            outline.isItemExpanded($0)
        }.map {
            $0.value.id
        }.sorted {
            $0.uuidString < $1.uuidString
        }
    }

    /// 业务作用：定义完整发布后还原项目树的展开与选择，正文焦点和文档集合保持原状。
    /// 参数说明:
    /// - expanded: 归档中属于当前定义的展开分组身份。
    /// - selected: 当前定义中需要重新选择的稳定节点。
    /// 返回：有界状态完整应用；失效节点不创建占位或文件访问任务。
    public func restoreTreeState(expanded: [UUID], selected: UUID?) {
        guard expanded.count <= 20_000 else {
            return
        }
        let identities = Set(expanded)
        var pending = Array(roots.reversed())
        while let item = pending.popLast() {
            if identities.contains(item.value.id) {
                outline.expandItem(item)
            }
            pending.append(contentsOf: item.children.reversed())
        }
        if let selected {
            reveal(selected)
        }
    }

    /// 业务作用：独立项目面板持有自己的树、选择和展开状态，仅向应用发送虚拟编辑意图。
    /// 参数说明:
    /// - frameRect: 当前面板的初始布局。
    /// 返回：可保存、载入、整理和键盘打开引用的原生项目树。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        commands.controlSize = .small
        let heading = NSStackView(views: [title, commands])
        heading.spacing = 6
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 23
        outline.indentationPerLevel = 13
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateSelection)
        outline.setAccessibilityLabel("虚拟项目与文件引用")
        outline.onActivate = {
            [weak self] in self?.activateSelection()
        }
        outline.onContextMenu = {
            [weak self] row in
            guard let self else {
                return nil
            }
            let node = (self.outline.item(atRow: row) as? ProjectTreeItem)?.value.id
            return self.makeMenu(node: node)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        state.font = .systemFont(ofSize: 10)
        state.maximumNumberOfLines = 2
        state.lineBreakMode = .byTruncatingTail
        state.textColor = .secondaryLabelColor
        for view in [heading, scroll, state] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -4),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            state.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            state.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateCommands()
    }

    /// 业务作用：项目面板由工作区显式建立，原生归档不能自动恢复磁盘访问入口。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：发布完整虚拟树并保留仍存在的选择、展开及视口，不读取引用文件。
    /// 参数说明:
    /// - name: 当前工作区显示名称。
    /// - entries: 完整有效展示节点；为空表示面板尚未载入工作区。
    /// - generation: 当前定义身份，旧菜单不能用于另一份定义。
    /// - dirty: 当前定义是否尚未保存到工作区文件。
    /// - feedback: 当前业务状态或失败原因。
    /// - boundToFile: 当前定义是否已绑定可重新载入的工作区文件。
    /// - busy: 当前面板是否正在完成定义读取或写入。
    /// 返回：结构有效才整体发布；无效结构保留旧树并反馈，不改变正文焦点。
    @discardableResult public func present(
        name: String,
        entries: [ProjectTreeEntry]?,
        generation: UUID,
        dirty: Bool,
        feedback: String,
        boundToFile: Bool = false,
        busy: Bool = false
    ) -> Bool {
        let values = entries ?? []
        var definitions: [UUID: ProjectTreeEntry] = [:]
        guard values.count <= 20_000 else {
            state.stringValue = "项目展示超过 20000 项，未发布部分树。"
            return false
        }
        var remaining = 4 * 1024 * 1024
        for value in values {
            let size = value.name.utf8.count + (value.pathHint?.utf8.count ?? 0)
            guard definitions.updateValue(value, forKey: value.id) == nil,
                !value.name.isEmpty, value.name.utf8.count <= 1024, !value.name.utf8.contains(0),
                value.pathHint.map({
                    !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.utf8.contains(0)
                }) ?? true,
                value.parent != nil || value.pathHint == nil, size <= remaining
            else {
                state.stringValue = "项目展示身份、原文或容量无效，原树保留。"
                return false
            }
            remaining -= size
        }
        for value in values {
            var ancestry: Set<UUID> = [value.id]
            var parent = value.parent
            while let identity = parent {
                // 缺失、文件父节点、循环或过深结构都不能进入原生树表递归。
                guard let owner = definitions[identity], owner.pathHint == nil,
                    ancestry.insert(identity).inserted, ancestry.count <= 64
                else {
                    state.stringValue = "项目展示结构无效，原树保留。"
                    return false
                }
                parent = owner.parent
            }
        }
        let selected = selectedNode
        let expanded = Set(
            items.values.filter {
                outline.isItemExpanded($0)
            }.map {
                $0.value.id
            }
        )
        let clip = outline.enclosingScrollView?.contentView
        let viewport = clip?.bounds
        var next: [UUID: ProjectTreeItem] = [:]
        for value in values {
            let item = items[value.id] ?? ProjectTreeItem(value)
            item.value = value
            item.children = []
            next[value.id] = item
        }
        var roots: [ProjectTreeItem] = []
        for value in values {
            guard let item = next[value.id] else {
                continue
            }
            if let parent = value.parent {
                next[parent]?.children.append(item)
            }
            else {
                roots.append(item)
            }
        }
        self.generation = generation
        loaded = entries != nil
        self.boundToFile = boundToFile
        self.busy = busy
        items = next
        self.roots = roots
        title.stringValue = name + (dirty ? " *" : "")
        title.toolTip = name
        state.stringValue = feedback
        state.toolTip = feedback
        outline.reloadData()
        var pending = Array(roots.reversed())
        while let item = pending.popLast() {
            if expanded.contains(item.value.id) {
                outline.expandItem(item)
            }
            pending.append(contentsOf: item.children.reversed())
        }
        if let selected, let item = items[selected] {
            let row = outline.row(forItem: item)
            outline.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
        }
        else {
            outline.deselectAll(nil)
        }
        if let clip, let viewport {
            clip.scroll(to: clip.constrainBoundsRect(viewport).origin)
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        updateCommands()
        return true
    }

    /// 业务作用：用户新增或定位虚拟节点后显式展开其父分组并选择该节点，普通后台刷新不调用此入口。
    /// 参数说明:
    /// - id: 当前定义中需要显示的稳定身份。
    /// 返回：存在时展开并滚动到节点；失效身份不改变当前选择。
    public func reveal(_ id: UUID) {
        guard let item = items[id] else {
            return
        }
        var ancestors: [ProjectTreeItem] = []
        var parent = item.value.parent
        while let identity = parent, let owner = items[identity] {
            ancestors.append(owner)
            parent = owner.value.parent
        }
        for owner in ancestors.reversed() {
            outline.expandItem(owner)
        }
        let row = outline.row(forItem: item)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }
}
