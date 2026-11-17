import AppKit

extension ProjectTreePanel {
    /// 业务作用：动作菜单绑定完整定义身份和稳定节点，重排或重新载入后旧菜单不能编辑新目标。
    /// 参数说明:
    /// - node: 当前动作所针对的节点，空值表示工作区本身。
    /// 返回：当前工作区和虚拟角色适用的原生菜单，不启动任何文件动作。
    func makeMenu(node: UUID?) -> NSMenu {
        let menu = NSMenu()
        for (id, title) in [
            ("new", "新建工作区"), ("load", "载入工作区…"),
            ("save", "保存工作区"), ("saveAs", "工作区另存为…"), ("reload", "重新载入工作区"),
            ("addProject", "添加项目…"), ("addFolder", "添加虚拟分组…"),
            ("addFiles", "加入文件引用…"), ("addDirectory", "从目录加入引用…"),
            ("rename", "修改显示名称…"), ("changePath", "修改文件引用路径…"),
            ("moveUp", "上移"), ("moveDown", "下移"), ("remove", "移除虚拟节点…"),
            ("unload", "关闭工作区"),
        ] {
            let item = NSMenuItem(
                title: title,
                action: #selector(performProjectAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.representedObject = ProjectMenuTarget(
                generation: generation,
                node: node
            )
            item.isEnabled = permits(id, node: node)
            menu.addItem(item)
        }
        return menu
    }

    /// 业务作用：选择变化后重建工具菜单，菜单标签始终引用稳定身份而非树表行号。
    /// 参数说明: 无。
    /// 返回：下拉入口保留工作区动作，并按当前节点角色启用虚拟编辑。
    func updateCommands() {
        commands.removeAllItems()
        commands.addItem(withTitle: "操作")
        let menu = makeMenu(node: selectedNode)
        for item in Array(menu.items) {
            menu.removeItem(item)
            commands.menu?.addItem(item)
        }
    }

    /// 业务作用：区分未载入、工作区和文件角色，虚拟文件不能成为新节点的父分组。
    /// 参数说明:
    /// - action: 具体虚拟动作。
    /// - node: 原菜单绑定的节点身份。
    /// 返回：当前工作区和角色允许该动作时为真。
    func permits(_ action: String, node: UUID?) -> Bool {
        // 定义 I/O 尚未收束时不再授予同一面板的新动作，不能把完成状态记到另一轮编辑。
        guard !busy else {
            return false
        }
        if action == "new" || action == "load" {
            return true
        }
        guard loaded else {
            return false
        }
        switch action {
        case "save", "saveAs", "unload", "addProject":
            return true
        case "reload":
            return boundToFile
        case "addFolder", "addFiles", "addDirectory":
            guard let node, let item = items[node] else {
                return false
            }
            return item.value.pathHint == nil
        case "changePath":
            return node.flatMap {
                items[$0]
            }?.value.pathHint != nil
        case "rename", "moveUp", "moveDown", "remove":
            return node.flatMap {
                items[$0]
            } != nil
        default:
            return false
        }
    }

    /// 业务作用：菜单显示期间定义可能改变，原菜单的稳定身份仍须通过当前发布代次与角色复验。
    /// 参数说明:
    /// - menuItem: 当前原生菜单项。
    /// 返回：仍属于当前定义且角色有效时启用。
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.identifier?.rawValue,
            let target = menuItem.representedObject as? ProjectMenuTarget
        else {
            return false
        }
        return target.generation == generation && permits(action, node: target.node)
    }

    /// 业务作用：原生动作只发出虚拟编辑意图，失效菜单不会借重排后的行号操作另一条文件引用。
    /// 参数说明:
    /// - sender: 绑定定义代次和节点的菜单项。
    /// 返回：当前有效意图交给应用，否则保留定义并反馈重新选择。
    @objc func performProjectAction(_ sender: NSMenuItem) {
        // 旧菜单没有新定义的编辑权，必须在调用应用协调器之前拒绝。
        guard let action = sender.identifier?.rawValue,
            let target = sender.representedObject as? ProjectMenuTarget,
            target.generation == generation
        else {
            state.stringValue = "项目定义已改变，请重新选择操作。"
            return
        }
        guard permits(action, node: target.node) else {
            state.stringValue = busy ? "项目工作区仍在处理，请稍后重试。" : "当前虚拟节点不适用该操作。"
            return
        }
        onAction?(action, target.node)
    }

    /// 业务作用：文件节点请求统一打开，虚拟分组仅改变本面板的展开状态。
    /// 参数说明: 无。
    /// 返回：文件发送稳定节点身份，分组展开或收起，不执行磁盘操作。
    @objc func activateSelection() {
        // 定义尚未载入或仍在处理时，文件激活也不能绕过同一面板的动作门禁。
        guard loaded, !busy else {
            return
        }
        guard let node = selectedNode, let item = items[node] else {
            return
        }
        if item.value.pathHint != nil {
            onOpen?(node)
        }
        else if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        }
        else {
            outline.expandItem(item)
        }
    }
}
