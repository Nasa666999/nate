import AppKit
import NateCore

struct EditorDropIntent {
    enum Kind {
        case files
        case text
    }

    let kind: Kind
    let sequence: Int
    weak var window: NSWindow?
    let pasteboard: NSPasteboard.Name
    let pasteboardChange: Int
    weak var document: DocumentBuffer?
    let revision: UInt64
    let authority: UUID
}

extension EditorView {
    /// 业务作用：真实文件拖入工作区，纯文本拖入登记当前正文和原生手势来源。
    /// 参数说明:
    /// - sender: 系统拖放上下文。
    /// 返回：只接受文件或可编辑文本。
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropIntent = nil
        guard let window, window === sender.draggingDestinationWindow,
            sender.draggingSourceOperationMask.contains(.copy)
        else {
            return []
        }
        let board = sender.draggingPasteboard
        let kind: EditorDropIntent.Kind
        // 仅按剪贴板显式声明的类型选路，正文中看似文件网址的文字仍然按文本插入。
        if board.types?.contains(.fileURL) == true {
            guard onOpenURLs != nil else {
                return []
            }
            kind = .files
        }
        else {
            // 候选和编辑保护仍持有正文，拖动不能取得提交权或主动结束候选。
            guard !document.isReadOnly, !document.isEditingSuspended, !hasMarkedText(),
                board.types?.contains(.string) == true
            else {
                return []
            }
            kind = .text
        }
        dropIntent = EditorDropIntent(
            kind: kind,
            sequence: sender.draggingSequenceNumber,
            window: window,
            pasteboard: board.name,
            pasteboardChange: board.changeCount,
            document: document,
            revision: document.revision,
            authority: document.editingAuthorityGeneration
        )
        return .copy
    }

    /// 业务作用：源文档或权限在拖动期间变化时撤下可放置反馈，不在更新事件中重新授权。
    /// 参数说明:
    /// - sender: 流经当前编辑视图的原生拖放上下文。
    /// 返回：现存文件入口或仍有效的正文拖放才表示可复制。
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        validatedDropKind(sender) == nil ? [] : .copy
    }

    /// 业务作用：拖动离开原编辑区域时结束该视图拥有的文件或正文授权。
    /// 参数说明:
    /// - sender: AppKit 通知的原生拖放上下文。
    /// 返回：旧进入事件不能为后来拖放保留有效来源。
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropIntent = nil
    }

    /// 业务作用：文件只沿工作区入口打开，文本按真实落点一次发布正文与结果光标。
    /// 参数说明:
    /// - sender: 拖放上下文。
    /// 返回：文件交接或文本事务成功时为真，任何文本失败保留先前的完整选择和正文。
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dropIntent = nil
        }
        guard let window, let kind = validatedDropKind(sender) else {
            return false
        }
        let board = sender.draggingPasteboard
        if kind == .files {
            guard let open = onOpenURLs,
                let urls = fileDropURLs(board), validatedDropKind(sender) == .files
            else {
                return false
            }
            open(urls)
            return true
        }
        let location = convert(sender.draggingLocation, from: nil)
        guard visibleRect.contains(location),
            let data = board.data(forType: .string), (1...64 * 1024 * 1024).contains(data.count),
            let text = UTF8Text.decode(data), validatedDropKind(sender) == .text,
            let offset = laidOutBytePosition(at: location)
        else {
            return false
        }
        // 焦点交接可触发生命周期回调。交接后复验，防止旧坐标写入已改变的正文。
        guard window.makeFirstResponder(self), validatedDropKind(sender) == .text,
            let primary = viewSelectionState?.primary,
            synchronizeDocumentSelectionState()
        else {
            return false
        }
        do {
            let caret = offset + data.count
            let result = try SelectionState(entries: [
                SelectionEntry(id: primary.id, selection: TextSelection(anchor: caret, head: caret))
            ])
            let transaction = try PreparedTransaction(
                snapshot: document.snapshot,
                edits: [TextEdit(ByteRange(offset, offset), text)],
                selectionStateAfter: result,
                name: "拖入文本"
            )
            // 不提前移动原主选区，撤销才能同时恢复真实选择、形态和正文。
            guard try document.commit(transaction) else {
                return false
            }
            refresh(reveal: true)
            onCommand?("unrecordedEditorCommand")
            onChange?()
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：拖放只沿进入时获准的窗口、载荷和类型交接，正文还需保持原修订及编辑资格。
    /// 参数说明:
    /// - sender: 当前原生拖放上下文。
    /// 返回：已确认的文件或文本类别，手势过期或来源改变时为空。
    private func validatedDropKind(_ sender: any NSDraggingInfo) -> EditorDropIntent.Kind? {
        guard let intent = dropIntent, let window, intent.window === window,
            sender.draggingDestinationWindow === window, sender.draggingSourceOperationMask.contains(.copy),
            sender.draggingSequenceNumber == intent.sequence
        else {
            return nil
        }
        let board = sender.draggingPasteboard
        // 拖动源替换载荷会撤回旧授权，尤其不能借正文拖入事件打开新的文件。
        guard intent.pasteboard == board.name, intent.pasteboardChange == board.changeCount else {
            return nil
        }
        if intent.kind == .files {
            return onOpenURLs == nil ? nil : .files
        }
        guard intent.document === document, intent.revision == document.revision,
            intent.authority == document.editingAuthorityGeneration, !document.isReadOnly,
            !document.isEditingSuspended, !hasMarkedText()
        else {
            return nil
        }
        return .text
    }

    /// 业务作用：只将原生拖放中的明确文件项交给工作区打开入口。
    /// 参数说明:
    /// - board: 本次拖动专用剪贴板。
    /// 返回：最多 1024 项文件 URL，任何一项缺失或无效时不打开这批文件。
    private func fileDropURLs(_ board: NSPasteboard) -> [URL]? {
        guard let items = board.pasteboardItems, (1...1024).contains(items.count) else {
            return nil
        }
        var urls: [URL] = []
        for item in items {
            guard item.types.contains(.fileURL), let value = item.string(forType: .fileURL),
                let url = URL(string: value), url.isFileURL
            else {
                return nil
            }
            urls.append(url)
        }
        return urls
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
