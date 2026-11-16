import AppKit
import NateCore

extension EditorView {
    /// 业务作用：将原生字形命中映射到完整 UTF-8 边界。
    /// 参数说明:
    /// - point: 本视图坐标。
    /// 返回：有效正文位置，超出行尾时停在行尾。
    func bytePosition(at point: NSPoint) -> Int {
        let tree = displayTree
        let line = max(0, min(tree.lineCount - 1, Int(max(0, point.y - 8) / lineHeight)))
        let layout = layoutLine(line)
        let local = layout.character(at: NSPoint(x: max(0, point.x - gutterWidth), y: 0))
        var units = min(tree.utf16Count, max(layout.originUTF16, layout.originUTF16 + local))
        while units > layout.originUTF16 && tree.byteOffset(utf16: units) == nil {
            units -= 1
        }
        return min(layout.range.upper, tree.byteOffset(utf16: units) ?? layout.range.lower)
    }

    /// 业务作用：分别处理书签、整行选择、多光标和普通文本拖选。
    /// 参数说明:
    /// - event: 鼠标按下事件。
    /// 返回：建立确定的拖选锚点，边栏不会意外修改正文。
    public override func mouseDown(with event: NSEvent) {
        finishComposition()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let position = bytePosition(at: point)
        let row = document.text.lineNumber(at: position)
        if point.x - visibleRect.minX < 18 {
            if document.bookmarks.contains(row) {
                document.bookmarks.remove(row)
            }
            else {
                document.bookmarks.insert(row)
            }
            needsDisplay = true
            onSelection?()
            return
        }
        if point.x - visibleRect.minX < gutterWidth || event.clickCount >= 3 {
            let range = document.text.lineRange(row)
            document.selections = [TextSelection(anchor: range.lower, head: range.upper)]
        }
        else if event.clickCount == 2 {
            let range = document.text.lineRange(row, includeEnding: false)
            let text = document.text.text(in: range)
            var offset = range.lower
            var lower = position
            var upper = position
            for word in text.split(
                omittingEmptySubsequences: false,
                whereSeparator: {
                    !$0.isLetter && !$0.isNumber && $0 != "_"
                }
            ) {
                let count = word.utf8.count
                if position >= offset && position <= offset + count {
                    lower = offset
                    upper = offset + count
                    break
                }
                offset += count + 1
            }
            document.selections = [TextSelection(anchor: lower, head: upper)]
        }
        else if event.modifierFlags.contains(.command) {
            document.selections.append(TextSelection(anchor: position, head: position))
        }
        else if event.modifierFlags.contains(.shift), let first = document.selections.first {
            document.selections = [TextSelection(anchor: first.anchor, head: position)]
        }
        else {
            document.selections = [TextSelection(anchor: position, head: position)]
        }
        dragAnchor = document.selections.first?.anchor
        dragColumn = event.modifierFlags.contains(.option) ? point.x : nil
        needsDisplay = true
        onSelection?()
    }

    /// 业务作用：在边缘持续滚动拖选，Option 拖动建立按视觉列的矩形目标。
    /// 参数说明:
    /// - event: 当前鼠标拖动事件。
    /// 返回：更新选区，短行虚拟列只保存在选区中。
    public override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else {
            return
        }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let position = bytePosition(at: point)
        if let startX = dragColumn {
            let a = document.text.lineNumber(at: anchor)
            let b = document.text.lineNumber(at: position)
            document.selections = (min(a, b)...max(a, b)).map {
                line in
                let y = CGFloat(line) * lineHeight + 9
                let lower = bytePosition(at: NSPoint(x: min(startX, point.x), y: y))
                let upper = bytePosition(at: NSPoint(x: max(startX, point.x), y: y))
                let layout = layoutLine(line)
                let end = layout.caret(at: layout.content.rendered.length).minX + gutterWidth
                let virtual = Int(max(0, min(startX, point.x) - end) / max(1, font.maximumAdvancement.width))
                return TextSelection(anchor: lower, head: upper, virtualColumn: virtual)
            }
        }
        else {
            document.selections = [TextSelection(anchor: anchor, head: position)]
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
    }

    /// 业务作用：全选真实正文，软换行和语法呈现不参与范围。
    /// 参数说明:
    /// - sender: 菜单或键盘来源。
    /// 返回：仅更新选区。
    @objc public override func selectAll(_ sender: Any?) {
        document.selections = [TextSelection(anchor: 0, head: document.text.byteCount)]
        needsDisplay = true
        onSelection?()
    }

    /// 业务作用：复制多选正文并保留片段元数据，NUL 不被截断。
    /// 参数说明:
    /// - sender: 命令来源。
    /// 返回：系统剪贴板包含普通文本及本应用片段。
    @objc public func copy(_ sender: Any?) {
        let selections = document.normalizedSelections()
        let pieces = selections.map {
            document.text.text(in: $0.range)
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(pieces.joined(separator: newline), forType: .string)
        if let data = try? JSONEncoder().encode(pieces) {
            board.setData(data, forType: NSPasteboard.PasteboardType("org.nate.text-fragments"))
        }
        onCommand?("rememberClipboard")
    }

    /// 业务作用：剪切先成功复制，再通过统一事务删除当前选区。
    /// 参数说明:
    /// - sender: 命令来源。
    /// 返回：形成一个可撤销删除动作。
    @objc public func cut(_ sender: Any?) {
        guard !document.isReadOnly else {
            return
        }
        copy(sender)
        insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：多片段与多目标等量时逐项粘贴，否则完整文本用于每个目标。
    /// 参数说明:
    /// - sender: 命令来源。
    /// 返回：一个完整撤销单元，不静默丢弃片段。
    @objc public func paste(_ sender: Any?) {
        finishComposition()
        let board = NSPasteboard.general
        let targets = document.normalizedSelections()
        if let data = board.data(forType: NSPasteboard.PasteboardType("org.nate.text-fragments")),
            let pieces = try? JSONDecoder().decode([String].self, from: data), pieces.count == targets.count
        {
            do {
                try document.commit(
                    zip(targets, pieces).map {
                        TextEdit($0.0.range, $0.1)
                    },
                    name: "粘贴"
                )
                refresh(reveal: true)
                onChange?()
            }
            catch {
                NSSound.beep()
            }
        }
        else if let value = board.string(forType: .string) {
            insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// 业务作用：让 VoiceOver 获取唯一已提交正文。
    /// 参数说明: 无。
    /// 返回：不包含预编辑的正文。
    public override func accessibilityValue() -> Any? {
        document.text.text()
    }

    /// 业务作用：辅助功能与原生文本服务使用同一选区单位。
    /// 参数说明: 无。
    /// 返回：主选区 UTF-16 范围。
    public override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    /// 业务作用：允许系统辅助服务通过事务替换整篇正文。
    /// 参数说明:
    /// - value: 系统提交的新正文。
    /// 返回：可撤销正文修改；只读时拒绝。
    public override func setAccessibilityValue(_ value: Any?) {
        guard let text = value as? String else {
            return
        }
        do {
            try document.commit([TextEdit(ByteRange(0, document.text.byteCount), text)], name: "辅助功能编辑")
            refresh()
            onChange?()
        }
        catch {
            NSSound.beep()
        }
    }
}
