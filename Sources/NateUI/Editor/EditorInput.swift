import AppKit
import NateCore

extension EditorView {
    /// 业务作用：按键先交给系统输入法，兼容快捷键仅在没有组合候选时分发。
    /// 参数说明:
    /// - event: 当前键盘事件。
    /// 返回：系统文本解释或统一命令分发，不重复插入键盘文字。
    public override func keyDown(with event: NSEvent) {
        if composition == nil, completionPanel?.handle(event) == true {
            return
        }
        if composition == nil && event.modifierFlags.contains(.control),
            let key = event.charactersIgnoringModifiers?.lowercased()
        {
            let commands = [
                "h": "replace", "f": "find", "s": "save", "n": "new", "o": "open", "w": "close", "g": "goto",
            ]
            if let functionKey = UnicodeScalar(NSF3FunctionKey), key == String(functionKey) {
                let previous = event.modifierFlags.contains(.shift)
                let temporary = event.modifierFlags.contains(.option)
                onCommand?(
                    temporary
                        ? (previous ? "volatileFindPrevious" : "volatileFindNext")
                        : (previous ? "selectFindPrevious" : "selectFindNext")
                )
                return
            }
            if key == "\t" {
                onCommand?(event.modifierFlags.contains(.shift) ? "previousTab" : "nextTab")
                return
            }
            if key == "i", event.modifierFlags.contains(.option) {
                onCommand?("incrementalSearch")
                return
            }
            if key == "b" {
                onCommand?(event.modifierFlags.contains(.option) ? "selectBracketPair" : "matchingBracket")
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
    /// 返回：正文命令只使用唯一历史；输入法取消撤去覆盖层后通知临时呈现重新读取已提交正文。
    public override func doCommand(by selector: Selector) {
        let command = NSStringFromSelector(selector)
        if composition == nil,
            command.hasPrefix("move") || command == "selectAll:" || command == "cancelOperation:"
        {
            clearRectangularSelection()
        }
        switch command {
        case "complete:": onCommand?("complete")
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
        case "moveToBeginningOfLine:", "moveToBeginningOfParagraph:", "moveToLeftEndOfLine:":
            move(edge: -1)
        case "moveToEndOfLine:", "moveToEndOfParagraph:", "moveToRightEndOfLine:":
            move(edge: 1)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:",
            "moveToBeginningOfParagraphAndModifySelection:":
            move(edge: -1, extend: true)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
            "moveToEndOfParagraphAndModifySelection:":
            move(edge: 1, extend: true)
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
                // 覆盖层已撤去才允许重新匹配已提交正文，不能把候选或旧任务恢复为高亮来源。
                onCommand?("compositionEnded")
            }
            else if let first = viewSelections.first {
                // Esc 属于新的选择意图，必须通知工作区撤销等待读取，不能只重绘本视图。
                viewSelections = [first]
                needsDisplay = true
                onSelection?()
            }
        default: NSSound.beep()
        }
    }

    /// 业务作用：逐字删除不切开扩展字形簇，多光标操作一次提交。
    /// 参数说明:
    /// - forward: 是否删除光标后的字形。
    /// 返回：一个可撤销事务；虚拟空白删除不写入空格，完整字形边界无法在共享预算内确定时整次不执行。
    func delete(forward: Bool) {
        finishComposition()
        var navigation: GraphemeNavigation
        do {
            navigation = try GraphemeNavigation(text: document.text)
        }
        catch {
            onStatus?(error.localizedDescription)
            return
        }
        var ranges: [ByteRange] = []
        var after: [TextSelection] = []
        for selection in document.normalizedSelections() {
            if selection.range.isEmpty && selection.virtualColumn > 0 {
                after.append(
                    TextSelection(
                        anchor: selection.head,
                        head: selection.head,
                        virtualColumn: max(0, selection.virtualColumn - (forward ? 0 : 1))
                    )
                )
                continue
            }
            let range: ByteRange
            do {
                range =
                    selection.range.isEmpty
                    ? try navigation.range(at: selection.head, forward: forward) : selection.range
            }
            catch {
                // 所有目标共用完整边界证据；任一目标超限时不能只删除此前已准备的其它光标范围。
                onStatus?(error.localizedDescription)
                return
            }
            if !range.isEmpty {
                ranges.append(range)
            }
            after.append(TextSelection(anchor: range.lower, head: range.lower))
        }
        var merged: [ByteRange] = []
        for range in ranges.sorted(by: {
            $0.lower < $1.lower
        }) {
            if let last = merged.last, range.lower <= last.upper {
                merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
            }
            else {
                merged.append(range)
            }
        }
        let edits = merged.map {
            TextEdit($0, "")
        }
        do {
            let positions = try PositionMap(edits: edits)
            after = after.map {
                TextSelection(
                    anchor: positions.map($0.anchor),
                    head: positions.map($0.head),
                    virtualColumn: $0.virtualColumn
                )
            }
            let changed = try document.commit(edits, selectionsAfter: after, name: forward ? "向后删除" : "退格")
            viewSelections = after
            refresh(reveal: true)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：保持原生字形坐标的行列移动和带方向选区。
    /// 参数说明:
    /// - horizontal: 逐字方向。
    /// - vertical: 可见行方向，跨过已收起的正文。
    /// - edge: 当前行首或行尾。
    /// - extend: 是否保留固定端。
    /// 返回：完整计算后更新全部视图选区，不产生修改修订；边界预算不足时保留全部原选择。
    func move(horizontal: Int = 0, vertical: Int = 0, edge: Int = 0, extend: Bool = false) {
        finishComposition()
        do {
            var navigation = try GraphemeNavigation(text: document.text)
            let after = try viewSelections.map {
                selection in
                var head = selection.head
                let row = document.text.lineNumber(at: head)
                if horizontal != 0 {
                    if !extend && !selection.range.isEmpty {
                        head = horizontal < 0 ? selection.range.lower : selection.range.upper
                    }
                    else {
                        head = try navigation.boundary(from: head, forward: horizontal > 0)
                    }
                }
                else if edge != 0 {
                    let range = document.text.lineRange(row, includeEnding: false)
                    head = edge < 0 ? range.lower : range.upper
                }
                else {
                    let target = projection.adjacentLine(to: row, direction: vertical)
                    let units = document.text.utf16Offset(byte: head) ?? 0
                    let layout = layoutLine(row)
                    let p = layout.caret(at: units - layout.originUTF16)
                    head = bytePosition(at: NSPoint(x: gutterWidth + p.minX, y: projection.y(of: target) + 9))
                }
                return TextSelection(anchor: extend ? selection.anchor : head, head: head)
            }
            // 全部光标的原始边界均已取得才发布，失败不能留下只有部分光标移动的状态。
            viewSelections = after
            needsDisplay = true
            revealSelection()
            onSelection?()
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：按 Unicode 词字符边界跳转，不把字节位置当字符下标。
    /// 参数说明:
    /// - forward: 跳转方向。
    /// 返回：有完整边界证据时光标移动，正文保持不变；共享字形预算不足时保留原位置并说明原因。
    func moveWord(forward: Bool) {
        guard let selection = viewSelections.first else {
            return
        }
        let tree = document.text
        var position = selection.head
        var moved = false
        do {
            var navigation = try GraphemeNavigation(text: tree)
            for _ in 0..<10_000 {
                let next = try navigation.boundary(from: position, forward: forward)
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
        catch {
            onStatus?(error.localizedDescription)
        }
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
