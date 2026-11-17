import AppKit

public struct DirectoryTreeEntry: Sendable {
    public let path: String
    public let isDirectory: Bool

    /// 业务作用：目录树只接收已读取的展示信息，不在绘制或展开回调中访问文件系统。
    /// 参数说明:
    /// - path: 完整实际路径。
    /// - isDirectory: 是否允许按需展开。
    /// 返回：可跨执行边界传递的单项展示值。
    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

private final class DirectoryTreeNode: NSObject {
    let path: String
    let isDirectory: Bool
    var children: [DirectoryTreeNode] = []
    var loaded = false
    var loading = false
    var failureMessage: String?

    /// 业务作用：为原生目录树保留稳定行身份，刷新时可继续保留展开与选择状态。
    /// 参数说明:
    /// - path: 原始完整路径。
    /// - isDirectory: 可展开的真实目录标识。
    /// 返回：尚未读取后代的展示节点。
    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

private final class DirectoryOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?

    /// 业务作用：回车打开选中文件或展开目录，其余键保留原生树表导航。
    /// 参数说明:
    /// - event: 当前原生键盘事件。
    /// 返回：回车发出统一激活意图，其余交给原生控件。
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
public final class DirectoryTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public var onLoad: ((String) -> Void)?
    public var onOpen: ((String) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onClose: (() -> Void)?
    private let outline = DirectoryOutlineView()
    private let state = NSTextField(labelWithString: "请选择目录工作区。")
    private var root: DirectoryTreeNode?
    private var nodes: [Data: DirectoryTreeNode] = [:]

    /// 业务作用：建立独立目录侧栏，树表仅发出读取和打开意图，结果面板继续保留原有内容。
    /// 参数说明:
    /// - frameRect: 主窗口提供的初始区域。
    /// 返回：可键盘导航、按需展开及手动刷新的目录树。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "目录工作区")
        title.font = .boldSystemFont(ofSize: 12)
        let refresh = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新目录")
                ?? NSImage(),
            target: self,
            action: #selector(refreshAction)
        )
        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭目录工作区") ?? NSImage(),
            target: self,
            action: #selector(closeAction)
        )
        refresh.bezelStyle = .inline
        close.bezelStyle = .inline
        let heading = NSStackView(views: [title, NSView(), refresh, close])
        heading.spacing = 6
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 23
        outline.indentationPerLevel = 13
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateSelection)
        outline.setAccessibilityLabel("目录工作区文件树")
        outline.onActivate = {
            [weak self] in self?.activateSelection()
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        state.font = .systemFont(ofSize: 10)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        state.maximumNumberOfLines = 2
        for view in [heading, scroll, state] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -4),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            state.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            state.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// 业务作用：目录侧栏由当前工作区显式创建，不从失效窗口归档恢复路径。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：新目录取得展示权时清除原根的节点，旧异步清单不能沿同名节点覆盖新工作区。
    /// 参数说明:
    /// - path: 用户明确选择的新根目录。
    /// 返回：只显示一个待展开根节点，不移动正文焦点或清除结果面板。
    public func setRoot(_ path: String) {
        let node = DirectoryTreeNode(
            path: path,
            isDirectory: true
        )
        root = node
        nodes = [Data(path.utf8): node]
        outline.reloadData()
        state.stringValue = "正在读取目录…"
        state.toolTip = path
    }

    /// 业务作用：确认待发布的目录仍在当前树中，移出的后代不能继续取得读取或打开入口。
    /// 参数说明:
    /// - path: 待复验的完整路径。
    /// 返回：当前树中仍有同字节路径的目录时为真。
    public func containsDirectory(_ path: String) -> Bool {
        nodes[Data(path.utf8)]?.isDirectory == true
    }

    /// 业务作用：文件打开等待期间复验原条目仍属于当前目录树，已移除路径不能由迟到请求重新打开。
    /// 参数说明:
    /// - path: 原激活条目的完整路径。
    /// 返回：当前树仍持有同字节路径时为真。
    public func containsPath(_ path: String) -> Bool {
        nodes[Data(path.utf8)] != nil
    }

    /// 业务作用：关闭目录工作区时释放旧树，隐藏侧栏不继续持有过期路径集合。
    /// 参数说明: 无。
    /// 返回：根与所有行对象释放，侧栏回到未选择目录的状态。
    public func clear() {
        root = nil
        nodes.removeAll()
        outline.reloadData()
        state.stringValue = "请选择目录工作区。"
        state.toolTip = nil
    }

    /// 业务作用：仅发布当前目录的一层，复用未改变的节点身份以保留展开状态和选择。
    /// 参数说明:
    /// - path: 当前待刷新的父目录。
    /// - entries: 已完成后台读取的完整条目。
    /// 返回：容量允许时整体更新；超过树总计 20000 节点时保留原清单并明确反馈。
    @discardableResult public func present(_ path: String, entries: [DirectoryTreeEntry]) -> Bool {
        // 父节点已经移出当前树时不能沿旧路径发布后代。
        guard let parent = nodes[Data(path.utf8)], parent.isDirectory else {
            return false
        }
        let parentKey = Data(path.utf8)
        var identities: Set<Data> = []
        // 发布只接受父目录的直接后代，重复、自引用或跨层路径不能形成循环或覆盖另一分支。
        guard
            entries.allSatisfy({
                entry in
                let key = Data(entry.path.utf8)
                return key != parentKey
                    && (entry.path as NSString).deletingLastPathComponent.utf8.elementsEqual(path.utf8)
                    && identities.insert(key).inserted
            })
        else {
            parent.loading = false
            parent.failureMessage = "目录清单与父节点不一致，未发布。"
            updateStatus()
            return false
        }
        let selected = outline.selectedRowIndexes.compactMap {
            outline.item(atRow: $0) as? DirectoryTreeNode
        }
        let clip = outline.enclosingScrollView?.contentView
        let viewport = clip?.bounds
        var next: [DirectoryTreeNode] = []
        for entry in entries {
            if let existing = nodes[Data(entry.path.utf8)], existing.isDirectory == entry.isDirectory {
                next.append(existing)
            }
            else {
                next.append(
                    DirectoryTreeNode(
                        path: entry.path,
                        isDirectory: entry.isDirectory
                    )
                )
            }
        }
        var rebuilt: [Data: DirectoryTreeNode] = [:]
        /// 业务作用：为整层替换构建候选索引，容量校验前不改变当前树。
        /// 参数说明:
        /// - node: 当前递归的稳定节点。
        /// 返回：候选索引包含保留后代与新一层的完整集合。
        func collect(_ node: DirectoryTreeNode) {
            rebuilt[Data(node.path.utf8)] = node
            for child in node === parent ? next : node.children {
                collect(child)
            }
        }
        if let root {
            collect(root)
        }
        // 先验证整个候选集合，再发布节点与展开状态，容量不足不能留下部分目录树。
        guard rebuilt.count <= 20_000 else {
            parent.loading = false
            parent.failureMessage = "目录树超过 20000 项，请收缩工作区范围。"
            updateStatus()
            return false
        }
        parent.children = next
        parent.loaded = true
        parent.loading = false
        parent.failureMessage = nil
        nodes = rebuilt
        outline.reloadItem(parent, reloadChildren: true)
        if parent === root {
            outline.expandItem(parent)
        }
        // 原生 reload 会保留行号而不保证条目身份，按仍存活的原对象恢复选择，不能选中插入到旧行号的新文件。
        let rows = selected.compactMap {
            node -> Int? in
            guard nodes[Data(node.path.utf8)] === node else {
                return nil
            }
            let row = outline.row(forItem: node)
            return row >= 0 ? row : nil
        }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if let clip, let viewport {
            clip.scroll(to: clip.constrainBoundsRect(viewport).origin)
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        updateStatus()
        return true
    }

    /// 业务作用：读取失败与空目录分开呈现，旧条目不能继续冒充最新目录状态。
    /// 参数说明:
    /// - path: 失败的当前目录。
    /// - message: 可读失败原因。
    /// 返回：父目录保留可重试入口，旧子树移出展示并显示失败原因。
    public func fail(_ path: String, message: String) {
        guard let node = nodes[Data(path.utf8)] else {
            return
        }
        _ = present(path, entries: [])
        node.loaded = false
        node.loading = false
        node.failureMessage = message
        outline.reloadItem(node)
        updateStatus()
    }

    /// 业务作用：一个目录读取失败不能被另一目录的成功刷新掩盖，目录树持续反馈未读取范围。
    /// 参数说明: 无。
    /// 返回：显示当前条目数和失败目录数，提示保留一个具体失败原因。
    private func updateStatus() {
        let failures = nodes.values.compactMap(\.failureMessage)
        if let first = failures.first {
            state.stringValue = "\(nodes.count - 1) 项 · \(failures.count) 个目录读取失败"
            state.toolTip = first
        }
        else {
            state.stringValue = "\(nodes.count - 1) 项 · 按需展开 · 自动观察变化"
            state.toolTip = root?.path
        }
    }

    /// 业务作用：原生树表只查询当前内存快照，不在布局时执行磁盘枚举。
    /// 参数说明:
    /// - outlineView: 当前目录树。
    /// - item: 父行对象，空值表示根层。
    /// 返回：根行或当前已读取的子行数量。
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? DirectoryTreeNode)?.children.count ?? (root == nil ? 0 : 1)
    }

    /// 业务作用：把原生子行索引映射到稳定展示节点。
    /// 参数说明:
    /// - outlineView: 当前目录树。
    /// - index: 有效子行索引。
    /// - item: 父节点或根层。
    /// 返回：当前内存快照中的节点对象；根不存在时为空占位，不持有导航权限。
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? DirectoryTreeNode {
            return item.children[index]
        }
        guard let root else {
            return NSNull()
        }
        return root
    }

    /// 业务作用：真实目录在尚未读取时也保留展开箭头，普通文件不显示虚假后代。
    /// 参数说明:
    /// - outlineView: 当前目录树。
    /// - item: 当前行。
    /// 返回：目录为真，文件为假。
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DirectoryTreeNode)?.isDirectory == true
    }

    /// 业务作用：首次展开发出异步读取意图，重复布局通知不能重复排队同一目录。
    /// 参数说明:
    /// - outlineView: 当前目录树。
    /// - item: 用户正在展开的节点。
    /// 返回：允许原生展开；尚未加载时发出一次读取请求。
    public func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let node = item as? DirectoryTreeNode, !node.loaded, !node.loading {
            node.loading = true
            onLoad?(node.path)
        }
        return true
    }

    /// 业务作用：以有界单行名称呈现路径，不让文件名中的换行改变树表行关系。
    /// 参数说明:
    /// - outlineView: 当前目录树。
    /// - tableColumn: 当前名称列。
    /// - item: 已读取节点。
    /// 返回：可复用原生文本单元格，不执行文件类型探测。
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let node = item as? DirectoryTreeNode else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("directory-name")
        let field =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        let name = (node.path as NSString).lastPathComponent
        field.stringValue =
            (node.failureMessage != nil ? "⚠︎ " : node.isDirectory ? "▸ " : "")
            + name
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip =
            node.path
            + (node.failureMessage.map {
                "\n" + $0
            } ?? "")
        return field
    }

    /// 业务作用：目录展开和文件打开分别路由，双击与回车不直接访问磁盘或改写正文。
    /// 参数说明: 无。
    /// 返回：目录切换展开状态，文件只发出显式打开意图。
    @objc private func activateSelection() {
        guard let node = outline.item(atRow: outline.selectedRow) as? DirectoryTreeNode else {
            return
        }
        if node.isDirectory {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            }
            else {
                outline.expandItem(node)
            }
        }
        else {
            onOpen?(node.path)
        }
    }

    /// 业务作用：用户主动刷新走应用协调入口，不在原生按钮回调中同步枚举目录。
    /// 参数说明: 无。
    /// 返回：发出重新读取意图。
    @objc private func refreshAction() {
        onRefresh?()
    }

    /// 业务作用：关闭侧栏交由应用撤销任务与观察资格，不能留下不可见目录的后台发布。
    /// 参数说明: 无。
    /// 返回：发出关闭目录工作区的意图。
    @objc private func closeAction() {
        onClose?()
    }
}
