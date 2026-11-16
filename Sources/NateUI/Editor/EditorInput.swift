import AppKit
import NateCore

extension EditorView {
    /// 业务作用：按键先交给系统输入法，兼容快捷键仅在没有组合候选时分发。
    /// 参数说明:
    /// - event: 当前键盘事件。
    /// 返回：系统文本解释或统一命令分发，不重复插入键盘文字。
    public override func keyDown(with event: NSEvent) {
        if composition == nil && event.modifierFlags.contains(.control),
            let key = event.charactersIgnoringModifiers?.lowercased()
        {
            let commands = [
                "h": "replace", "f": "find", "s": "save", "n": "new", "o": "open", "w": "close", "g": "goto",
            ]
            if key == "\t" {
                onCommand?(event.modifierFlags.contains(.shift) ? "previousTab" : "nextTab")
                return
            }
            if let command = commands[key] {
                onCommand?(command)
                return
            }
        }
        interpretKeyEvents([event])
    }

    /// 业务作用：系统编辑命令统一转换为内核事务或选区变更。
    /// 参数说明:
    /// - selector: 原生输入上下文解析出的动作。
    /// 返回：正文命令只使用唯一历史，输入法取消只撤去覆盖层。
    public override func doCommand(by selector: Selector) {
        let command = NSStringFromSelector(selector)
        switch command {
        case "insertNewline:":
            var indent = ""
            if let head = viewSelections.first?.head {
                let row = document.text.lineNumber(at: head)
                indent = String(
                    document.text.text(in: document.text.lineRange(row, includeEnding: false)).prefix {
                        $0 == " " || $0 == "\t"
                    }
                )
            }
            insertText(newline + indent, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "insertTab:": insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "deleteBackward:": delete(forward: false)
        case "deleteForward:": delete(forward: true)
        case "moveLeft:", "moveBackward:": move(horizontal: -1)
        case "moveRight:", "moveForward:": move(horizontal: 1)
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:":
            move(horizontal: -1, extend: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:":
            move(horizontal: 1, extend: true)
        case "moveUp:": move(vertical: -1)
        case "moveDown:": move(vertical: 1)
        case "moveUpAndModifySelection:": move(vertical: -1, extend: true)
        case "moveDownAndModifySelection:": move(vertical: 1, extend: true)
        case "moveToBeginningOfLine:", "moveToBeginningOfParagraph:": move(edge: -1)
        case "moveToEndOfLine:", "moveToEndOfParagraph:": move(edge: 1)
        case "moveToBeginningOfLineAndModifySelection:": move(edge: -1, extend: true)
        case "moveToEndOfLineAndModifySelection:": move(edge: 1, extend: true)
        case "moveToBeginningOfDocument:": setCaret(0)
        case "moveToEndOfDocument:": setCaret(document.text.byteCount)
        case "moveWordLeft:", "moveWordBackward:": moveWord(forward: false)
        case "moveWordRight:", "moveWordForward:": moveWord(forward: true)
        case "selectAll:": selectAll(nil)
        case "cancelOperation:":
            if composition != nil {
                composition = nil
                inputContext?.discardMarkedText()
                refresh()
            }
            else if let first = viewSelections.first {
                viewSelections = [first]
                needsDisplay = true
            }
        default: NSSound.beep()
        }
    }

    /// 业务作用：逐字删除不切开扩展字形簇，多光标操作一次提交。
    /// 参数说明:
    /// - forward: 是否删除光标后的字形。
    /// 返回：一个可撤销事务；虚拟空白删除不写入空格。
    func delete(forward: Bool) {
        finishComposition()
        viewSelections = document.normalizedSelections().map {
            selection in
            guard selection.range.isEmpty, selection.virtualColumn == 0 else {
                return selection
            }
            let other = document.text.graphemeBoundary(from: selection.head, forward: forward)
            return TextSelection(anchor: selection.head, head: other)
        }
        insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：保持原生字形坐标的行列移动和带方向选区。
    /// 参数说明:
    /// - horizontal: 逐字方向。
    /// - vertical: 真实行方向。
    /// - edge: 当前行首或行尾。
    /// - extend: 是否保留固定端。
    /// 返回：仅更新视图选区，不产生修改修订。
    func move(horizontal: Int = 0, vertical: Int = 0, edge: Int = 0, extend: Bool = false) {
        finishComposition()
        viewSelections = viewSelections.map {
            selection in
            var head = selection.head
            let row = document.text.lineNumber(at: head)
            if horizontal != 0 {
                head = document.text.graphemeBoundary(from: head, forward: horizontal > 0)
            }
            else if edge != 0 {
                let range = document.text.lineRange(row, includeEnding: false)
                head = edge < 0 ? range.lower : range.upper
            }
            else {
                let target = max(0, min(document.text.lineCount - 1, row + vertical))
                let units = document.text.utf16Offset(byte: head) ?? 0
                let layout = layoutLine(row)
                let p = layout.caret(at: units - layout.originUTF16)
                head = bytePosition(at: NSPoint(x: gutterWidth + p.minX, y: projection.y(of: target) + 9))
            }
            return TextSelection(anchor: extend ? selection.anchor : head, head: head)
        }
        needsDisplay = true
        revealSelection()
        onSelection?()
    }

    /// 业务作用：按 Unicode 词字符边界跳转，不把字节位置当字符下标。
    /// 参数说明:
    /// - forward: 跳转方向。
    /// 返回：光标移动，正文保持不变。
    func moveWord(forward: Bool) {
        guard let selection = viewSelections.first else {
            return
        }
        let tree = document.text
        var position = selection.head
        var moved = false
        for _ in 0..<10_000 {
            let next = tree.graphemeBoundary(from: position, forward: forward)
            if next == position {
                break
            }
            let word = tree.text(in: ByteRange(min(position, next), max(position, next)))
            if moved
                && word.allSatisfy({
                    !$0.isLetter && !$0.isNumber && $0 != "_"
                })
            {
                break
            }
            position = next
            moved = true
        }
        setCaret(position)
    }

    /// 业务作用：统一主动导航后的焦点与选区通知。
    /// 参数说明:
    /// - position: 已验证字节位置。
    /// 返回：显示对应光标且不修改正文。
    public func setCaret(_ position: Int) {
        guard document.text.isBoundary(position) else {
            return
        }
        viewSelections = [TextSelection(anchor: position, head: position)]
        needsDisplay = true
        revealSelection()
        onSelection?()
    }
}
