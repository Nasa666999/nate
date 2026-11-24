import AppKit
import NateCore

struct CompositionSession {
    let revision: UInt64
    let originalRange: ByteRange
    let replacementOverride: ByteRange?
    let virtualPadding: Int
    let displaySuffix: Int
    let selectionState: SelectionState?
    let selectionGeneration: UUID
    let documentSelectionGeneration: UUID
    let editingGeneration: UUID
    var text: String
    var selected: NSRange
}

extension EditorView {
    /// 业务作用：输入法预编辑只进入展示树，持久化和撤销始终读取原正文。
    /// 参数说明: 无。
    /// 返回：组合仍属于当前修订时的完整展示树，否则返回已提交正文。
    var displayTree: PieceTree {
        guard !confirmingComposition, let composition, composition.revision == document.revision else {
            return document.text
        }
        // 候选前的虚拟定位只进入展示树，确认前的自动保存和撤销来源仍保持原正文。
        let displayed =
            String(repeating: " ", count: composition.virtualPadding) + composition.text
            + String(repeating: " ", count: composition.displaySuffix)
        return (try? document.text.replacing(composition.originalRange, with: displayed))
            ?? document.text
    }

    /// 业务作用：在独立覆盖层中显示输入法候选，自动保存只读取已提交正文。
    /// 参数说明:
    /// - string: 预编辑文字或带属性候选。
    /// - selectedRange: 候选内部 UTF-16 选区。
    /// - replacementRange: 系统展示坐标中的替换范围。
    /// 返回：仅更新预编辑，不产生历史或修订。
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !confirmingComposition else {
            return
        }
        if let session = composition, !compositionIsCurrent(session) {
            // 新候选回调不重新授予旧组合权限，失效来源只能撤去，不能覆盖后来选择的正文。
            composition = nil
            inputContext?.discardMarkedText()
            refresh()
            onStatus?("原输入法组合的正文、选择或权限已改变，请重新输入。")
            return
        }
        completionPanel?.hide()
        guard !document.isReadOnly, !document.isEditingSuspended else {
            return
        }
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let units = value.utf16.count
        guard value.utf8.count <= 1_048_576, selectedRange.location != NSNotFound,
            selectedRange.location >= 0, selectedRange.location <= units,
            selectedRange.length >= 0, selectedRange.length <= units - selectedRange.location
        else {
            onStatus?("输入法候选范围无效或超过 1 MB，已保留原正文与当前组合。")
            return
        }
        if composition == nil {
            // 候选开始即撤销旧分隔符选择；随后取消候选也不能恢复原任务的选择权。
            boundaries.cancelDelimiterSelection()
            clipboard.cancel()
            guard synchronizeDocumentSelectionState() else {
                return
            }
            var range =
                replacementRange.location == NSNotFound
                ? primarySelection?.range : document.text.byteRange(replacementRange)
            var padding = replacementRange.location == NSNotFound ? primarySelection?.virtualColumn ?? 0 : 0
            var suffix = 0
            if replacementRange.location == NSNotFound {
                do {
                    if let target = try rectangularCompositionTarget() {
                        range = target.range
                        padding = target.leadingSpaces
                        suffix = target.trailingSpaces
                    }
                }
                catch {
                    onStatus?(error.localizedDescription)
                    return
                }
            }
            guard let range else {
                return
            }
            // 候选取得正文目标后撤销正在等待的文本落点，取消候选也不会恢复旧拖动权限。
            if dropIntent?.kind == .text {
                dropIntent = nil
            }
            composition = CompositionSession(
                revision: document.revision,
                originalRange: range,
                replacementOverride: replacementRange.location == NSNotFound ? nil : range,
                virtualPadding: padding,
                displaySuffix: suffix,
                selectionState: viewSelectionState,
                selectionGeneration: selectionGeneration,
                documentSelectionGeneration: document.selectionGeneration,
                editingGeneration: document.editingAuthorityGeneration,
                text: value,
                selected: selectedRange
            )
            // 进入候选即撤销旧搜索的发布权；随后取消候选也不能让旧请求重新获得原选区。
            onCommand?("compositionBegan")
        }
        else if composition?.revision == document.revision {
            composition?.text = value
            composition?.selected = selectedRange
        }
        else {
            // 另一视图已经提交时，旧组合不能写入失效范围。
            composition = nil
            inputContext?.discardMarkedText()
        }
        refresh()
    }

    /// 业务作用：最终输入只提交一次，多光标候选在确认时统一进入事务。
    /// 参数说明:
    /// - string: 系统确认的文字。
    /// - replacementRange: 无组合时可指定的 UTF-16 替换范围。
    /// 返回：实际正文变化形成一次撤销单元，相同文字只收束选择；失效组合或准备失败保留原正文与选择。
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if composition == nil, replacementRange.location == NSNotFound, !overwrite, value == ">",
            pairInsertionSettings.closeMarkupTags, language?.id == "html" || language?.id == "xml",
            case .stream? = viewSelectionState?.shape
        {
            _ = performEditorCommand(.insertMarkupTagEnd)
            return
        }
        if composition == nil, replacementRange.location == NSNotFound, !overwrite,
            case .stream? = viewSelectionState?.shape
        {
            do {
                if let command = try pairInsertionSettings.command(for: value) {
                    _ = submitPairInput(command)
                    return
                }
                if indentationSettings.automatic == .language,
                    value != ")" || language?.id == "rust" && userLanguage == nil,
                    let command = EditorCommand.allCases.first(where: { $0.structuralCharacter == value })
                {
                    _ = performEditorCommand(command)
                    return
                }
            }
            catch {
                onStatus?(error.localizedDescription)
                return
            }
        }
        _ = commitTextInput(value, replacementRange: replacementRange)
    }

    /// 业务作用：工具与宏等待真实输入结果，容量或候选确认失败后不能继续执行下一步动作。
    /// 参数说明:
    /// - value: 当前选择上需要完整提交的语义文字，不含虚拟列填充。
    /// 返回：真实提交或相同字节选择收束成功时为真；失败保留原正文、选择与仍有效候选。
    @discardableResult
    public func submitText(_ value: String) -> Bool {
        commitTextInput(value, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：系统解除标记时提交仍有效的候选，后续解除回调不会重复提交。
    /// 参数说明: 无。
    /// 返回：只在仍有组合时形成一次正式输入。
    public func unmarkText() {
        guard let session = composition else {
            return
        }
        insertText(session.text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：手动保存、切换或关闭前完成候选生命周期。
    /// 参数说明: 无。
    /// 返回：没有组合或确认成功时为真并解除系统标记；准备失败保留候选且为假，调用方不得继续切换或关闭。
    @discardableResult
    public func finishComposition() -> Bool {
        guard !confirmingComposition else {
            return false
        }
        guard let session = composition else {
            return true
        }
        guard commitTextInput(session.text, replacementRange: NSRange(location: NSNotFound, length: 0)),
            composition == nil
        else {
            return false
        }
        inputContext?.discardMarkedText()
        return true
    }

    /// 业务作用：向系统说明当前是否有预编辑候选。
    /// 参数说明: 无。
    /// 返回：组合覆盖层存在时为真。
    public func hasMarkedText() -> Bool {
        composition != nil
    }

    /// 业务作用：系统选区查询与预编辑展示使用同一 UTF-16 坐标。
    /// 参数说明: 无。
    /// 返回：当前展示选区；无有效范围时返回哨兵。
    public func selectedRange() -> NSRange {
        if let session = composition {
            let start = document.text.utf16Offset(byte: session.originalRange.lower) ?? 0
            return NSRange(
                location: start + session.virtualPadding + session.selected.location,
                length: session.selected.length
            )
        }
        return primarySelection.flatMap {
            document.text.nsRange($0.range)
        }
            ?? NSRange(location: 0, length: 0)
    }

    /// 业务作用：将输入法标记范围映射到临时展示正文。
    /// 参数说明: 无。
    /// 返回：当前候选范围；没有候选时返回系统哨兵。
    public func markedRange() -> NSRange {
        guard let session = composition else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(
            location: (document.text.utf16Offset(byte: session.originalRange.lower) ?? 0)
                + session.virtualPadding,
            length: session.text.utf16.count
        )
    }

    /// 业务作用：提供系统文本服务所需的周边文字，范围不跨越无效边界。
    /// 参数说明:
    /// - range: 系统展示坐标范围。
    /// - actualRange: 实际可读取的系统范围。
    /// 返回：该范围的只读文本，不替代内核正文。
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        guard let bytes = displayTree.byteRange(range) else {
            return nil
        }
        actualRange?.pointee = range
        return NSAttributedString(string: displayTree.text(in: bytes), attributes: [.font: font])
    }

    /// 业务作用：声明候选呈现接受的属性，正文不保存富文本样式。
    /// 参数说明: 无。
    /// 返回：可用于输入法覆盖层的属性列表。
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .foregroundColor]
    }

    /// 业务作用：使候选框跟随当前视图、滚动位置和显示器坐标。
    /// 参数说明:
    /// - range: 系统请求的展示范围。
    /// - actualRange: 实际候选锚点范围。
    /// 返回：屏幕坐标中的原生字形光标矩形；没有布局证据时返回空矩形及 NSNotFound 范围。
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let tree = displayTree
        let requested = range.location == NSNotFound ? selectedRange().location : range.location
        let offset =
            tree.byteOffset(utf16: min(requested == NSNotFound ? 0 : requested, tree.utf16Count))
            ?? 0
        let line = tree.lineNumber(at: offset)
        let layout = layoutLine(line)
        // 候选仍由原组合持有，没有字形证据时不能向系统提供伪造的输入锚点。
        guard layout.unavailableReason == nil else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return .zero
        }
        let units = tree.utf16Offset(byte: offset) ?? 0
        var rect = layout.caret(at: units - layout.originUTF16)
        rect.origin.x += gutterWidth
        if composition == nil, let primarySelection, offset == primarySelection.head {
            rect.origin.x += selectionCaretOffset(for: primarySelection)
        }
        rect.origin.y += projection.y(of: line) + 8
        actualRange?.pointee = NSRange(location: units, length: 0)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    /// 业务作用：将系统屏幕命中转换为当前展示文本位置。
    /// 参数说明:
    /// - point: 屏幕坐标。
    /// 返回：UTF-16 位置，不混用内核字节单位。
    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else {
            return NSNotFound
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        // 没有实际字形就没有可信像素命中，文本服务必须收到系统哨兵而非原光标的替代位置。
        guard layoutLine(projection.line(at: max(0, local.y - 8))).unavailableReason == nil else {
            return NSNotFound
        }
        return displayTree.utf16Offset(byte: bytePosition(at: local)) ?? NSNotFound
    }
}
