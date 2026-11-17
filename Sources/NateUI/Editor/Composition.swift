import AppKit
import NateCore

struct CompositionSession {
    let revision: UInt64
    let originalRange: ByteRange
    let selections: [TextSelection]
    var text: String
    var selected: NSRange
}

extension EditorView {
    /// 业务作用：在独立覆盖层中显示输入法候选，自动保存只读取已提交正文。
    /// 参数说明:
    /// - string: 预编辑文字或带属性候选。
    /// - selectedRange: 候选内部 UTF-16 选区。
    /// - replacementRange: 系统展示坐标中的替换范围。
    /// 返回：仅更新预编辑，不产生历史或修订。
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
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
            let range =
                replacementRange.location == NSNotFound
                ? viewSelections.first?.range : document.text.byteRange(replacementRange)
            guard let range else {
                return
            }
            composition = CompositionSession(
                revision: document.revision,
                originalRange: range,
                selections: viewSelections,
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
    /// 返回：一次撤销单元；失效组合不修改正文。
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if let session = composition {
            composition = nil
            guard session.revision == document.revision else {
                refresh()
                return
            }
            viewSelections = session.selections
            if session.selections.count == 1 {
                viewSelections = [
                    TextSelection(anchor: session.originalRange.lower, head: session.originalRange.upper)
                ]
            }
        }
        else if replacementRange.location != NSNotFound {
            guard let range = document.text.byteRange(replacementRange) else {
                return
            }
            viewSelections = [TextSelection(anchor: range.lower, head: range.upper)]
        }
        else if overwrite && !value.contains("\n") {
            viewSelections = viewSelections.map {
                if $0.range.isEmpty {
                    return TextSelection(
                        anchor: $0.head,
                        head: document.text.graphemeBoundary(from: $0.head, forward: true)
                    )
                }
                return $0
            }
        }
        do {
            document.selections = viewSelections
            try document.insert(value)
            refresh(reveal: true)
            onChange?()
            if value.utf16.count <= 2 {
                onCommand?("typingAssistance")
            }
        }
        catch {
            NSSound.beep()
        }
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
    /// 返回：已提交的候选与正文一致，系统标记被解除。
    public func finishComposition() {
        unmarkText()
        inputContext?.discardMarkedText()
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
            return NSRange(location: start + session.selected.location, length: session.selected.length)
        }
        return viewSelections.first.flatMap {
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
            location: document.text.utf16Offset(byte: session.originalRange.lower) ?? 0,
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
    /// 返回：屏幕坐标中的原生字形光标矩形。
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let tree = displayTree
        let requested = range.location == NSNotFound ? selectedRange().location : range.location
        let offset =
            tree.byteOffset(utf16: min(requested == NSNotFound ? 0 : requested, tree.utf16Count))
            ?? 0
        let line = tree.lineNumber(at: offset)
        let layout = layoutLine(line)
        let units = tree.utf16Offset(byte: offset) ?? 0
        var rect = layout.caret(at: units - layout.originUTF16)
        rect.origin.x += gutterWidth
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
        return displayTree.utf16Offset(byte: bytePosition(at: local)) ?? NSNotFound
    }
}
