import AppKit
import NateCore

extension EditorView {
    /// 业务作用：光标呈现与系统文本服务采用相同虚拟横坐标，反向矩形的活动端不跳到右边缘。
    /// 参数说明:
    /// - selection: 当前视图中的一项完整选择。
    /// 返回：相对真实原生光标的水平偏移，不向正文写入空格。
    func virtualCaretOffset(for selection: TextSelection) -> CGFloat {
        var columns = selection.virtualColumn
        if composition == nil, let state = viewSelectionState,
            case .rectangle(let rectangle) = state.shape,
            rectangle.headX >= rectangle.anchorX,
            let entry = state.entries.first(where: {
                $0.selection == selection
            }),
            let edge = rectangle.edges.first(where: {
                $0.selectionID == entry.id
            }),
            selection.head
                == document.text.lineRange(document.text.lineNumber(at: selection.head), includeEnding: false)
                .upper
        {
            columns += edge.trailingColumns
        }
        return CGFloat(Double(columns) * rectangleColumnWidth)
    }

    /// 业务作用：选中的行尾虚拟空白以真实块宽度显示，定位用空白不混入选中区域。
    /// 参数说明:
    /// - layout: 当前可见逻辑行的原生字形布局。
    /// - line: 当前真实逻辑行。
    /// - y: 当前逻辑行在文档视图中的纵向起点。
    /// 返回：只绘制虚拟尾部背景，正文、选择与其它视图保持不变。
    func drawVirtualRectangle(in layout: LineLayout, line: Int, y: CGFloat) {
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
        let end = layout.caret(at: layout.content.rendered.length)
        let width = CGFloat(rectangleColumnWidth)
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
