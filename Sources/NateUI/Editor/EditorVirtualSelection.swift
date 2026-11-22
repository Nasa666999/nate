import AppKit
import NateCore

extension EditorView {
    /// 业务作用：矩形的 Tab 边缘按实际选中列着色，保留未选中的 Tab 两侧，不把整份 Tab 显示为已选择。
    /// 参数说明:
    /// - layout: 当前可见真实行的原生布局。
    /// - line: 当前真实逻辑行。
    /// - y: 逻辑行在文档视图中的纵向起点。
    /// 返回：存在当前矩形行时完成实际正文部分的选择呈现并为真，其它选择由普通呈现继续处理。
    func drawRectangularSelection(in layout: LineLayout, line: Int, y: CGFloat) -> Bool {
        guard composition == nil, !hasStaleRectangleLayout, let state = viewSelectionState,
            case .rectangle(let rectangle) = state.shape,
            let entry = state.entries.first(where: {
                document.text.lineNumber(at: $0.selection.range.lower) == line
            })
        else {
            return false
        }
        let range = entry.selection.range
        var pieces = range.isEmpty ? [] : [range]
        let lowerX = CGFloat(min(rectangle.anchorX, rectangle.headX))
        let upperX = CGFloat(max(rectangle.anchorX, rectangle.headX))
        var tabs: Set<Int> = []
        for point in [range.lower, range.upper] {
            if point < layout.range.upper && document.text.byte(at: point) == 9 {
                tabs.insert(point)
            }
            if point > layout.range.lower && document.text.byte(at: point - 1) == 9 {
                tabs.insert(point - 1)
            }
        }
        var tabRects: [NSRect] = []
        for point in tabs {
            guard let units = document.text.utf16Offset(byte: point) else {
                continue
            }
            let first = layout.caret(at: units - layout.originUTF16)
            let last = layout.caret(at: units - layout.originUTF16 + 1)
            guard abs(first.midY - last.midY) < max(1, lineHeight / 2) else {
                continue
            }
            let a = max(lowerX, min(first.minX, last.minX))
            let b = min(upperX, max(first.minX, last.minX))
            guard a < b else {
                continue
            }
            // 原字节选择可能包含整份 Tab，先扣除它，再仅按视觉相交列绘制，不能重复叠加选择透明度。
            pieces = pieces.flatMap {
                piece -> [ByteRange] in
                guard point >= piece.lower, point < piece.upper else {
                    return [piece]
                }
                var remaining: [ByteRange] = []
                if piece.lower < point {
                    remaining.append(ByteRange(piece.lower, point))
                }
                if point + 1 < piece.upper {
                    remaining.append(ByteRange(point + 1, piece.upper))
                }
                return remaining
            }
            tabRects.append(
                NSRect(
                    x: gutterWidth + a,
                    y: y + first.minY,
                    width: b - a,
                    height: max(lineHeight, first.height)
                )
            )
        }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
        for piece in pieces {
            for rect in layout.selectionRects(piece) {
                rect.offsetBy(dx: gutterWidth, dy: y).fill()
            }
        }
        for rect in tabRects {
            rect.fill()
        }
        return true
    }

    /// 业务作用：光标呈现与系统文本服务对齐 Tab 内部及虚拟横坐标，反向矩形的活动端不跳到右边缘。
    /// 参数说明:
    /// - selection: 当前视图中的一项完整选择。
    /// 返回：相对真实原生光标的水平偏移，不向正文写入空格。
    func selectionCaretOffset(for selection: TextSelection) -> CGFloat {
        guard !hasStaleRectangleLayout else {
            return CGFloat(selection.virtualColumn) * CGFloat(rectangleColumnWidth(at: selection.head))
        }
        var columns = selection.virtualColumn
        if composition == nil, let state = viewSelectionState,
            case .rectangle(let rectangle) = state.shape,
            let entry = state.entries.first(where: {
                $0.selection == selection
            })
        {
            if let offset = rectangularTabCaretOffset(selection, headX: rectangle.headX) {
                return offset
            }
            if rectangle.headX >= rectangle.anchorX,
                let edge = rectangle.edges.first(where: {
                    $0.selectionID == entry.id
                }),
                selection.head
                    == document.text.lineRange(
                        document.text.lineNumber(at: selection.head),
                        includeEnding: false
                    ).upper
            {
                columns += edge.trailingColumns
            }
        }
        return CGFloat(Double(columns) * rectangleColumnWidth(at: selection.head))
    }

    /// 业务作用：矩形活动边缘位于 Tab 内部时保留可见光标列，系统查询不能跳到整份 Tab 的前后端。
    /// 参数说明:
    /// - selection: 仍以完整字节边界表示的当前行选择。
    /// - headX: 同一矩形的活动视觉横坐标。
    /// 返回：需要应用到原生光标的偏移；没有涉及 Tab 内部时为空。
    private func rectangularTabCaretOffset(_ selection: TextSelection, headX: Double) -> CGFloat? {
        let row = document.text.lineNumber(at: selection.head)
        let body = document.text.lineRange(row, includeEnding: false)
        var points: [Int] = []
        if selection.head < body.upper && document.text.byte(at: selection.head) == 9 {
            points.append(selection.head)
        }
        if selection.head > body.lower && document.text.byte(at: selection.head - 1) == 9 {
            points.append(selection.head - 1)
        }
        guard !points.isEmpty, let units = document.text.utf16Offset(byte: selection.head) else {
            return nil
        }
        let layout = layoutLine(row)
        let actual = layout.caret(at: units - layout.originUTF16)
        for point in points {
            guard let start = document.text.utf16Offset(byte: point) else {
                continue
            }
            let first = layout.caret(at: start - layout.originUTF16)
            let last = layout.caret(at: start - layout.originUTF16 + 1)
            guard abs(first.midY - last.midY) < max(1, lineHeight / 2),
                headX > Double(min(first.minX, last.minX)) + 0.01,
                headX < Double(max(first.minX, last.minX)) - 0.01
            else {
                continue
            }
            return CGFloat(headX) - actual.minX
        }
        return nil
    }

    /// 业务作用：选中的行尾虚拟空白以真实块宽度显示，定位用空白不混入选中区域。
    /// 参数说明:
    /// - layout: 当前可见逻辑行的原生字形布局。
    /// - line: 当前真实逻辑行。
    /// - y: 当前逻辑行在文档视图中的纵向起点。
    /// 返回：只绘制虚拟尾部背景，正文、选择与其它视图保持不变。
    func drawVirtualRectangle(in layout: LineLayout, line: Int, y: CGFloat) {
        guard !hasStaleRectangleLayout else {
            return
        }
        guard composition == nil, let state = viewSelectionState,
            case .rectangle(let rectangle) = state.shape,
            let entry = state.entries.first(where: {
                document.text.lineNumber(at: $0.selection.range.lower) == line
            }),
            let edge = rectangle.edges.first(where: {
                $0.selectionID == entry.id
            }),
            edge.trailingColumns > 0
        else {
            return
        }
        guard layout.renderedRange.upper == layout.range.upper else {
            return
        }
        let end = layout.caret(at: layout.characterCount)
        let width = CGFloat(layout.virtualColumnWidth)
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
        NSRect(
            x: gutterWidth + end.minX + CGFloat(edge.leadingColumns) * width,
            y: y + end.minY,
            width: CGFloat(edge.trailingColumns) * width,
            height: max(lineHeight, end.height)
        ).fill()
    }

    /// 业务作用：长矩形的虚拟边缘纳入滚动范围，自动换行也不会把行尾之外的选择裁掉。
    /// 参数说明: 无。
    /// 返回：当前矩形所需的最小画布宽度；普通选择不扩大画布。
    var virtualRectangleWidth: CGFloat {
        guard composition == nil, let state = viewSelectionState, case .rectangle(let rectangle) = state.shape
        else {
            return 0
        }
        return gutterWidth + CGFloat(max(rectangle.anchorX, rectangle.headX)) + 20
    }
}
