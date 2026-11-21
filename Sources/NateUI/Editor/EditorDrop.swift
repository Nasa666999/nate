import AppKit

extension EditorView {
    /// 业务作用：文件拖入进入工作区路由，文本拖入遵守只读权限。
    /// 参数说明:
    /// - sender: 系统拖放上下文。
    /// 返回：只接受文件或可编辑文本。
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        if board.availableType(from: [.fileURL]) != nil {
            return .copy
        }
        return !document.isReadOnly && board.availableType(from: [.string]) != nil ? .copy : []
    }

    /// 业务作用：文字拖入作为一个事务，文件不会被误当路径文字插入。
    /// 参数说明:
    /// - sender: 拖放上下文。
    /// 返回：成功处理拖放时为真。
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            onOpenURLs?(urls)
            return true
        }
        guard !document.isReadOnly, let text = board.string(forType: .string) else {
            return false
        }
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return false
        }
        setCaret(bytePosition(at: convert(sender.draggingLocation, from: nil)))
        return commitTextInput(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：正文右键菜单复用系统剪贴板与应用编辑命令。
    /// 参数说明:
    /// - event: 当前右键事件。
    /// 返回：属于当前视图和文档的操作菜单。
    public override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        for (title, selector) in [
            ("剪切", #selector(cut(_:))), ("复制", #selector(copy(_:))),
            ("粘贴", #selector(paste(_:))), ("全选", #selector(selectAll(_:))),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        for (title, command) in [
            ("撤销", "undo"), ("重做", "redo"), ("切换行注释", "comment"),
            ("打开选中路径", "openSelection"), ("在 Finder 定位选中路径", "revealSelection"), ("打开选中网址", "openURL"),
            ("搜索选区或当前词", "searchOnInternet"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        return menu
    }

    /// 业务作用：上下文指令由应用路由校验范围与权限。
    /// 参数说明:
    /// - sender: 用户选择的菜单项。
    /// 返回：发送当前视图动作。
    @objc func contextCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String {
            onCommand?(command)
        }
    }
}
