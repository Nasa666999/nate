import AppKit

extension EditorWindow {
    /// 业务作用：文档列表与标签共享名称、目录和全部状态，菜单项只携带稳定身份及原栏代次。
    /// 参数说明:
    /// - target: 共享业务路由的接收者。
    /// - action: 负责复验来源并执行激活的原生选择入口。
    /// 返回：完整列表；接收者在执行前仍须验证 identifier 中的代次，不能按名称猜测文档。
    public func documentListMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "文档列表")
        for tab in documentListOrder.sorted(tabs.current) {
            let item = NSMenuItem(
                title: tabs.displayLabels[tab.id] ?? tab.statusPrefix + tab.title,
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = "activate:" + tab.id.uuidString
            item.identifier = NSUserInterfaceItemIdentifier(
                tabs.orderIdentity.uuidString + "." + tab.id.uuidString
            )
            item.toolTip = tab.path ?? "未命名临时文档"
            item.state = tab.selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// 业务作用：窗口菜单与工具栏共享排序选项，并固定生成选项时的标签栏代次。
    /// 参数说明:
    /// - target: 共享业务路由的接收者。
    /// - action: 负责复验来源并选择排序方式的原生入口。
    /// 返回：包含当前选中状态的完整排序子菜单，实际执行仍由接收者校验。
    public func documentListOrderItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: "文档列表排序依据", action: nil, keyEquivalent: "")
        entry.identifier = NSUserInterfaceItemIdentifier("nate.documentListOrder")
        let submenu = NSMenu(title: entry.title)
        for order in DocumentListOrder.allCases {
            let item = NSMenuItem(title: order.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = "documentListOrder:" + order.rawValue
            item.identifier = NSUserInterfaceItemIdentifier(tabs.orderIdentity.uuidString)
            item.state = order == documentListOrder ? .on : .off
            submenu.addItem(item)
        }
        entry.submenu = submenu
        return entry
    }

    /// 业务作用：从工具栏打开当前完整文档列表，查看列表本身不切换正文或确认候选。
    /// 参数说明:
    /// - target: 共享业务路由的接收者。
    /// - action: 与窗口菜单相同的激活选择入口。
    /// 返回：原生列表从可见工具栏或标签栏展开，选择继续交由接收者复验身份和代次。
    public func showDocumentList(target: AnyObject, action: Selector) {
        guard !tabs.current.isEmpty else {
            return
        }
        let toolbarButton = toolbarStack.arrangedSubviews.first {
            $0.identifier?.rawValue == "documentList"
        }
        let anchor: NSView = isWorkspaceToolbarVisible ? toolbarButton ?? tabs : tabs
        let menu = documentListMenu(target: target, action: action)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(documentListOrderItem(target: target, action: action), at: 0)
        let search = NSMenuItem(title: "搜索已打开文档…", action: action, keyEquivalent: "")
        search.target = target
        search.representedObject = "documentListSearch"
        search.identifier = NSUserInterfaceItemIdentifier(
            "nate.documentListSearch." + tabOrderIdentity.uuidString
        )
        menu.insertItem(search, at: 0)
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(
                x: anchor.bounds.minX,
                y: anchor.bounds.maxY
            ),
            in: anchor
        )
    }

    /// 业务作用：在当前文档所属窗口使用相同的排序及标签命名搜索，不读取任何磁盘路径。
    /// 参数说明:
    /// - onSelect: 接收稳定文档身份，负责在表单关闭后复验窗口和标签。
    /// 返回：没有标签或窗口已有其它表单时保持界面，取消不会触发切换。
    public func searchDocumentList(onSelect: @escaping (UUID) -> Void) {
        guard let window, window.attachedSheet == nil, !tabs.current.isEmpty else {
            return
        }
        let search = DocumentListSearch(
            documents: documentListOrder.sorted(tabs.current),
            labels: tabs.displayLabels
        )
        search.present(in: window, onSelect: onSelect)
    }
}
