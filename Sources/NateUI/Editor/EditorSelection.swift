import AppKit
import NateCore

extension EditorView {
    /// 业务作用：将原生字形命中映射到完整 UTF-8 边界。
    /// 参数说明:
    /// - point: 本视图坐标。
    /// 返回：有效正文位置，超出行尾时停在行尾；缺少字形时保留原光标并反馈原因。
    func bytePosition(at point: NSPoint) -> Int {
        if let position = laidOutBytePosition(at: point) {
            return position
        }
        let tree = displayTree
        let line = projection.line(at: max(0, point.y - 8))
        return min(tree.byteCount, primarySelection?.head ?? tree.lineStart(line))
    }

    /// 业务作用：以真实字形证据确认输入落点，供不能沿用原光标的动作使用。
    /// 参数说明:
    /// - point: 本视图坐标。
    /// 返回：对应的完整字节边界，排版不可用时反馈原因并返回空。
    func laidOutBytePosition(at point: NSPoint) -> Int? {
        let tree = displayTree
        let line = projection.line(at: max(0, point.y - 8))
        let layout = layoutLine(line)
        // 没有实际字形时不能把占位起点当成用户新选择，保留原光标并交付具体原因。
        if let reason = layout.unavailableReason {
            onStatus?(reason)
            return nil
        }
        let local = layout.character(
            at: NSPoint(x: max(0, point.x - gutterWidth), y: point.y - projection.y(of: line) - 8)
        )
        // 系统哨兵或越界位置必须先收束到本段范围，再叠加正文起点，不能先做可能溢出的算术。
        let origin = min(tree.utf16Count, max(0, layout.originUTF16))
        let bounded = min(tree.utf16Count - origin, max(0, min(layout.characterCount, local)))
        var units = origin + bounded
        while units > layout.originUTF16 && tree.byteOffset(utf16: units) == nil {
            units -= 1
        }
        return min(layout.range.upper, tree.byteOffset(utf16: units) ?? layout.range.lower)
    }

    /// 业务作用：分别处理书签、整行、配置分隔符、完整 Unicode 单词、多光标和普通文本拖选。
    /// 参数说明:
    /// - event: 鼠标按下事件。
    /// 返回：建立确定的拖选锚点，边栏不修改正文，单词超出 262144 个标量时保留光标并明确反馈。
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let gutterX = point.x - visibleRect.minX
        let bookmarkClick = gutterX < 18
        // 修改历史的最右细栏止于折叠图形左侧，点击状态列只能选择行，不能取得折叠动作。
        let foldClick = gutterX >= gutterWidth - 16 && gutterX < gutterWidth
        // 边栏动作不拥有正文提交权，候选仍在时不能借书签或折叠点击把预编辑写入正文。
        guard composition == nil || !bookmarkClick && !foldClick else {
            onStatus?("请先确认或取消当前候选，再操作书签或折叠。")
            return
        }
        // 关闭或恢复保护固定了当前元数据，书签点击不能在保护期间改写这份集合。
        guard !bookmarkClick || !document.isEditingSuspended else {
            onStatus?("文档处于编辑保护，书签暂不改变。")
            return
        }
        guard !document.isEditingSuspended || foldClick else {
            onStatus?("文档处于编辑保护，正文选择保持原状。")
            return
        }
        let requestedLine = projection.line(at: max(0, point.y - 8))
        if gutterX >= gutterWidth, let reason = layoutLine(requestedLine).unavailableReason {
            onStatus?(reason)
            return
        }
        if composition == nil, openTextLink(with: event) {
            return
        }
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return
        }
        boundaries.cancelDelimiterSelection()
        window?.makeFirstResponder(self)
        let position =
            gutterX < gutterWidth ? document.text.lineStart(requestedLine) : bytePosition(at: point)
        let row = document.text.lineNumber(at: position)
        if bookmarkClick {
            if document.bookmarks.contains(row) {
                document.bookmarks.remove(row)
            }
            else {
                guard document.bookmarks.count < 100_000 else {
                    onStatus?("书签最多保留十万行，已有书签保持不变。")
                    return
                }
                document.bookmarks.insert(row)
            }
            needsDisplay = true
            onSelection?()
            return
        }
        if foldClick {
            dragAnchor = nil
            dragColumn = nil
            if let region = folds.index?.region(at: row), region.startLine == row {
                performFold(.toggle, line: row)
            }
            return
        }
        if event.clickCount == 2,
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        {
            selectInsideConfiguredDelimiters(at: position)
            return
        }
        clearRectangularSelection()
        var wordNotice: String?
        if point.x - visibleRect.minX < gutterWidth || event.clickCount >= 3 {
            let range = document.text.lineRange(row)
            viewSelections = [TextSelection(anchor: range.lower, head: range.upper)]
        }
        else if event.clickCount == 2 {
            let range: ByteRange
            // 分隔符也可能占多个字节，直接沿标量边界找整词，不复制整行或按一个字节推算词首。
            switch document.text.wordSelection(
                at: position,
                maximumScalars: 262_144,
                wordBoundaries: wordBoundaries
            ) {
            case .word(let word):
                range = word
            case .noWord:
                range = ByteRange(position, position)
            case .exceedsLimit:
                range = ByteRange(position, position)
                wordNotice = "单词超过 262144 个 Unicode 标量，未截断选择；可直接拖选需要的正文范围。"
            }
            viewSelections = [
                TextSelection(
                    anchor: range.lower,
                    head: range.upper
                )
            ]
        }
        else if event.modifierFlags.contains(.command) {
            if let state = viewSelectionState,
                let existing = state.entries.first(where: {
                    $0.selection.range.isEmpty && $0.selection.head == position
                        && $0.selection.virtualColumn == 0
                })
            {
                try? setSelectionState(state.selectingPrimary(existing.id))
            }
            else {
                viewSelections.append(TextSelection(anchor: position, head: position))
                if let state = viewSelectionState, let last = state.entries.last {
                    try? setSelectionState(state.selectingPrimary(last.id))
                }
            }
        }
        else if event.modifierFlags.contains(.shift), let first = primarySelection {
            viewSelections = [TextSelection(anchor: first.anchor, head: position)]
        }
        else {
            viewSelections = [TextSelection(anchor: position, head: position)]
        }
        dragAnchor = primarySelection?.anchor
        dragColumn = event.modifierFlags.contains(.option) ? point.x : nil
        dragRevision = document.revision
        dragSelectionID = viewSelectionState?.primaryID
        dragAppending = event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option)
        if dragColumn != nil, event.clickCount == 1,
            !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift)
        {
            _ = setRectangularSelections(viewSelections)
        }
        needsDisplay = true
        onSelection?()
        // 选区变化回调会刷新状态栏，先发布实际选区，再显示未能完成整词选择的原因。
        if let wordNotice {
            onStatus?(wordNotice)
        }
    }

    /// 业务作用：在边缘持续滚动拖选，Option 拖动建立按视觉列的矩形目标。
    /// 参数说明:
    /// - event: 当前鼠标拖动事件。
    /// 返回：更新选区，短行虚拟列只保存在选区中。
    public override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else {
            return
        }
        // 拖选锚点只属于按下时的正文；另一事务已经提交后不能把旧字节起点套入新内容。
        guard dragRevision == document.revision, !document.isEditingSuspended else {
            dragAnchor = nil
            dragColumn = nil
            dragSelectionID = nil
            onStatus?("正文或编辑保护已改变，本次拖选已结束。")
            return
        }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let position = bytePosition(at: point)
        if let startX = dragColumn {
            let a = document.text.lineNumber(at: anchor)
            let b = document.text.lineNumber(at: position)
            guard
                setVisualRectangle(
                    anchorRow: a,
                    headRow: b,
                    anchorX: Double(max(0, startX - gutterWidth)),
                    headX: Double(max(0, point.x - gutterWidth))
                )
            else {
                return
            }
        }
        else if dragAppending, let id = dragSelectionID, let state = viewSelectionState,
            let index = state.entries.firstIndex(where: {
                $0.id == id
            })
        {
            var entries = state.entries
            entries[index] = SelectionEntry(id: id, selection: TextSelection(anchor: anchor, head: position))
            do {
                try setSelectionState(SelectionState(entries: entries, primaryID: id))
            }
            catch {
                onStatus?(error.localizedDescription)
                return
            }
        }
        else {
            viewSelections = [TextSelection(anchor: anchor, head: position)]
        }
        needsDisplay = true
        onSelection?()
    }

    /// 业务作用：释放拖选状态，避免后续鼠标动作沿用旧矩形锚点。
    /// 参数说明:
    /// - event: 鼠标释放事件。
    /// 返回：结束当前拖选。
    public override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        dragColumn = nil
        dragRevision = nil
        dragSelectionID = nil
        dragAppending = false
    }

    /// 业务作用：全选真实正文，软换行和语法呈现不参与范围。
    /// 参数说明:
    /// - sender: 菜单或键盘来源。
    /// 返回：候选确认成功后全选最新正文；确认失败保留候选和原选择。
    @objc public override func selectAll(_ sender: Any?) {
        performEditorCommand(.selectAll)
    }

}
