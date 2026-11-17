import AppKit

extension ProjectTreePanel {
    /// 业务作用：原生树表从完整内存定义查询子节点数量，不在布局时读取文件。
    /// 参数说明:
    /// - outlineView: 当前项目树。
    /// - item: 当前父对象，空值表示工作区根层。
    /// 返回：根项目数或当前虚拟分组子节点数。
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ProjectTreeItem)?.children.count ?? roots.count
    }

    /// 业务作用：把原生行索引映射到稳定虚拟节点，不借索引推断实际文件路径。
    /// 参数说明:
    /// - outlineView: 当前项目树。
    /// - index: 当前层级有效子索引。
    /// - item: 父对象，空值表示根层。
    /// 返回：当前快照中的稳定行对象。
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ProjectTreeItem)?.children[index] ?? roots[index]
    }

    /// 业务作用：虚拟分组保留展开入口，文件引用不显示虚假子节点。
    /// 参数说明:
    /// - outlineView: 当前项目树。
    /// - item: 当前虚拟节点。
    /// 返回：非文件节点为真，文件节点为假。
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? ProjectTreeItem else {
            return false
        }
        return item.value.pathHint == nil
    }

    /// 业务作用：以单行安全标签显示虚拟名称，原始文件路径只在提示中显示而不参与文件访问。
    /// 参数说明:
    /// - outlineView: 当前项目树。
    /// - tableColumn: 当前名称列。
    /// - item: 待呈现虚拟节点。
    /// 返回：可复用文本单元格，换行与 Tab 不改变树表行关系。
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let item = item as? ProjectTreeItem else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("project-name")
        let field =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.stringValue = item.value.name
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "\\0")
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = item.value.pathHint ?? item.value.name
        return field
    }

    /// 业务作用：选择变化只更新本面板可执行动作，不改变正文光标或其他项目面板。
    /// 参数说明:
    /// - notification: 当前原生选择通知。
    /// 返回：菜单绑定当前稳定节点，不启动文件打开或定义写入。
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateCommands()
    }
}
