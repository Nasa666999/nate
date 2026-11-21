import AppKit
import NateCore

extension EditorView {
    /// 业务作用：按键先交给系统输入法，兼容快捷键仅在没有组合候选时分发。
    /// 参数说明:
    /// - event: 当前键盘事件。
    /// 返回：系统文本解释或统一命令分发，不重复插入键盘文字。
    public override func keyDown(with event: NSEvent) {
        if usesDefaultKeyboardRoutes, composition == nil,
            event.modifierFlags.intersection([.control, .option, .shift, .command]) == [
                .control, .option, .shift,
            ],
            [123, 124, 125, 126].contains(event.keyCode)
        {
            extendRectangle(
                horizontal: event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0,
                vertical: event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0
            )
            return
        }
        if composition == nil, completionPanel?.handle(event) == true {
            return
        }
        if usesDefaultKeyboardRoutes, composition == nil, let key = event.charactersIgnoringModifiers,
            let command = CompatibilityShortcut.command(
                key: key,
                modifiers: NativeKeyboardShortcut.modifierBits(event.modifierFlags)
            )
        {
            onCommand?(command)
            return
        }
        interpretKeyEvents([event])
    }

    /// 业务作用：系统编辑命令统一转换为内核事务或选区变更。
    /// 参数说明:
    /// - selector: 原生输入上下文解析出的动作。
    /// 返回：正文命令只使用唯一历史；输入法取消撤去覆盖层后通知临时呈现重新读取已提交正文。
    public override func doCommand(by selector: Selector) {
        let command = NSStringFromSelector(selector)
        if command != "cancelOperation:" || composition == nil,
            let semantic = Self.semanticCommand(command)
        {
            performEditorCommand(semantic)
            return
        }
        guard !document.isEditingSuspended || command == "cancelOperation:" && composition != nil else {
            onStatus?("文档处于编辑保护，输入与选择保持原状。")
            return
        }
        switch command {
        case "complete:": onCommand?("complete")
        case "insertNewline:":
            var indent = ""
            if let head = primarySelection?.head {
                let row = document.text.lineNumber(at: head)
                indent = String(
                    document.text.text(in: document.text.lineRange(row, includeEnding: false)).prefix {
                        $0 == " " || $0 == "\t"
                    }
                )
            }
            insertText(newline + indent, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "cancelOperation:":
            if composition != nil {
                composition = nil
                inputContext?.discardMarkedText()
                refresh()
                // 覆盖层已撤去才允许重新匹配已提交正文，不能把候选或旧任务恢复为高亮来源。
                onCommand?("compositionEnded")
            }
            else if let first = primarySelection {
                // Esc 属于新的选择意图，必须通知工作区撤销等待读取，不能只重绘本视图。
                viewSelections = [first]
                needsDisplay = true
                onSelection?()
            }
        default:
            onCommand?("unrecordedEditorCommand")
            NSSound.beep()
        }
    }

    /// 业务作用：逐字删除不切开扩展字形簇，多光标操作一次提交。
    /// 参数说明:
    /// - forward: 是否删除光标后的字形。
    /// 返回：完整事务或合法边界上的无变化为真，候选、权限或边界准备失败为假；虚拟空白不写入正文。
    @discardableResult
    func delete(forward: Bool) -> Bool {
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return false
        }
        if let state = viewSelectionState, case .rectangle(let shape) = state.shape, !shape.zeroWidth {
            // 正宽矩形即使实际字节范围为空也仍有列意图，删除不能退化为移除下一字形或整份 Tab。
            return commitTextInput(
                "",
                replacementRange: NSRange(location: NSNotFound, length: 0),
                recording: false
            )
        }
        if let state = viewSelectionState, case .rectangle = state.shape {
            do {
                guard synchronizeDocumentSelectionState() else {
                    return false
                }
                let changed = try document.commit(prepareRectangularDeletion(forward: forward))
                refresh(reveal: true)
                if changed {
                    onChange?()
                }
                else {
                    onSelection?()
                }
                return true
            }
            catch {
                onStatus?(error.localizedDescription)
                return false
            }
        }
        var navigation: GraphemeNavigation
        do {
            navigation = try GraphemeNavigation(text: document.text)
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
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
                return false
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
            if !changed {
                viewSelections = after
            }
            refresh(reveal: true)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：保持原生字形坐标的行列移动和带方向选区。
    /// 参数说明:
    /// - horizontal: 逐字方向。
    /// - vertical: 可见行方向，跨过已收起的正文。
    /// - edge: 当前行首或行尾。
    /// - extend: 是否保留固定端。
    /// 返回：全部选区移动或合法边界上的无变化为真；候选、边界或预算失败为假且保留当前状态。
    @discardableResult
    func move(horizontal: Int = 0, vertical: Int = 0, edge: Int = 0, extend: Bool = false) -> Bool {
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return false
        }
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
                    // 上下移动依赖两行实际字形，任一行缺少证据时不能发布近似光标或部分目标。
                    if let reason = layout.unavailableReason ?? layoutLine(target).unavailableReason {
                        throw NateError.message(reason)
                    }
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
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：按 Unicode 词字符边界跳转，不把字节位置当字符下标。
    /// 参数说明:
    /// - forward: 跳转方向。
    /// - extend: 保留每项原固定端以扩展选择。
    /// 返回：全部目标的词和字形边界完整时移动；一项超限则全部保持原状，不截取部分长词。
    @discardableResult
    func moveWord(forward: Bool, extend: Bool = false) -> Bool {
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return false
        }
        let tree = document.text
        do {
            var navigation = try GraphemeNavigation(text: tree)
            var remaining = 100_000
            let after = try viewSelections.map {
                selection in
                var position = selection.head
                var enteredWord = false
                while true {
                    guard remaining > 0 else {
                        throw NateError.message("按词导航超过十万字形共享预算，原选择保持不变。")
                    }
                    remaining -= 1
                    let next = try navigation.boundary(from: position, forward: forward)
                    if next == position {
                        break
                    }
                    let cluster = tree.text(in: ByteRange(min(position, next), max(position, next)))
                    let isWord = cluster.contains {
                        $0.isLetter || $0.isNumber || $0 == "_"
                    }
                    if enteredWord && !isWord {
                        break
                    }
                    enteredWord = enteredWord || isWord
                    position = next
                }
                return TextSelection(anchor: extend ? selection.anchor : position, head: position)
            }
            // 多光标共用预算且全部完成后才发布，不能因后一个长词失败而留下部分移动。
            viewSelections = after
            needsDisplay = true
            revealSelection()
            onSelection?()
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：统一主动导航后的焦点与选区通知。
    /// 参数说明:
    /// - position: 已验证字节位置。
    /// 返回：没有候选和编辑保护且字节合法时定位；否则保留当前选择，不替用户丢弃候选。
    public func setCaret(_ position: Int) {
        guard composition == nil, !document.isEditingSuspended else {
            onStatus?("请先确认或取消候选并解除编辑保护，再定位正文。")
            return
        }
        guard document.text.isBoundary(position) else {
            return
        }
        viewSelections = [TextSelection(anchor: position, head: position)]
        needsDisplay = true
        revealSelection()
        onSelection?()
    }
}
