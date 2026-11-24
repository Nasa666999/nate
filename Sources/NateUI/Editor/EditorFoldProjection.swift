import AppKit
import NateCore
import NateSyntax

struct EditorViewportAnchor {
    let line: Int
    let offset: CGFloat
    let x: CGFloat
}

struct EditorLayoutMetrics: Equatable {
    let font: NSFont
    let width: CGFloat
    let gutter: CGFloat
    let wrapping: Bool
    let rightToLeft: Bool
    let tabWidth: Int
    let showSequences: Bool
    var themeIdentity: String? = nil
}

extension EditorView {
    /// 业务作用：记录真实顶行及行内偏移，折叠和高度估计调整不使后台更新随意移动视口。
    /// 参数说明: 无。
    /// 返回：滚动容器存在时的轻量锚点，不持有正文或布局。
    func viewportAnchor() -> EditorViewportAnchor? {
        guard let clip = enclosingScrollView?.contentView else {
            return nil
        }
        let line = projection.line(at: max(0, clip.bounds.minY - 8))
        return EditorViewportAnchor(
            line: line,
            offset: clip.bounds.minY - projection.y(of: line) - 8,
            x: clip.bounds.minX
        )
    }

    /// 业务作用：投影变化后恢复可追踪的真实顶行，原顶行被收起时定位到最近可见标题。
    /// 参数说明:
    /// - anchor: 变化前的视口证据，没有滚动容器时为空。
    /// 返回：只调整滚动原点，不改变正文、选区和焦点。
    func restoreViewportAnchor(_ anchor: EditorViewportAnchor?) {
        guard let anchor, let scroll = enclosingScrollView else {
            return
        }
        let line = min(max(0, displayTree.lineCount - 1), anchor.line)
        let visible = hiddenLines.visibleBeforeOrAt(line)
        let y = projection.y(of: visible) + 8 + (visible == line ? anchor.offset : 0)
        let point = NSPoint(
            x: max(0, min(anchor.x, max(0, frame.width - scroll.contentSize.width))),
            y: max(0, min(y, max(0, frame.height - scroll.contentSize.height)))
        )
        if abs(scroll.contentView.bounds.minX - point.x) > 0.5
            || abs(scroll.contentView.bounds.minY - point.y) > 0.5
        {
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// 业务作用：文档地图的视口指示由正文当前真实像素投影得出。
    /// 参数说明: 无。
    /// 返回：当前可见的逻辑行范围，待确认输入或尚未形成视口时为空。
    func documentMapVisibleLines() -> Range<Int>? {
        guard !hasMarkedText(), let clip = enclosingScrollView?.contentView, clip.bounds.height > 0 else {
            return nil
        }
        let top = projection.line(at: max(0, clip.bounds.minY - 8))
        let bottom = projection.line(at: max(0, clip.bounds.maxY - 8))
        let count = max(1, document.text.lineCount)
        return min(top, count - 1)..<min(max(top, bottom) + 1, count)
    }

    /// 业务作用：地图导航滚动到用户指定逻辑行，使用实际折叠投影并保留当前光标。
    /// 参数说明:
    /// - line: 地图命中的当前正文逻辑行。
    /// 返回：定位到目标行或其可见折叠标题；候选未确认时保持原视口。
    func centerDocumentMapLine(_ line: Int) {
        guard !hasMarkedText(), let clip = enclosingScrollView?.contentView,
            (0..<document.text.lineCount).contains(line)
        else {
            return
        }
        restoreViewportAnchor(
            EditorViewportAnchor(
                line: hiddenLines.visibleBeforeOrAt(line),
                offset: -clip.bounds.height / 2,
                x: clip.bounds.minX
            )
        )
    }

    /// 业务作用：将本视图已确认的收起范围合并成隐藏行区间，预编辑期间临时展示完整正文。
    /// 参数说明: 无。
    /// 返回：更新像素投影，完整正文树和其它视图不受影响。
    func rebuildFoldVisibility() {
        guard composition == nil, let index = folds.index,
            index.documentID == document.id, index.revision == document.revision
        else {
            hiddenLines.removeAll()
            projection.hidden = hiddenLines
            return
        }
        hiddenLines = HiddenLineRanges(
            index.regions.filter {
                folds.collapsed.contains($0.range)
            }.map {
                ($0.startLine + 1)..<($0.endLine + 1)
            }
        )
        projection.hidden = hiddenLines
    }

    /// 业务作用：查找、括号和显式跳转进入隐藏正文时展开相应区域，使真实选区可以看见。
    /// 参数说明:
    /// - selection: 需要显示的明确选区，为空时使用当前主选区。
    /// 返回：仅展开挡住所选目标的块，内层其它收起状态仍保留。
    func unfoldSelection(_ selection: TextSelection? = nil) {
        synchronizeBracketContext()
        guard let index = folds.index, let selection = selection ?? primarySelection else {
            return
        }
        var removed = false
        let line = document.text.lineNumber(at: selection.head)
        for region in index.regions where folds.collapsed.contains(region.range) {
            let body = ByteRange(
                document.text.lineStart(region.startLine + 1),
                document.text.lineRange(region.endLine).upper
            )
            if (line > region.startLine && line <= region.endLine)
                || (!selection.range.isEmpty && selection.range.lower < body.upper
                    && selection.range.upper > body.lower)
            {
                folds.collapsed.remove(region.range)
                removed = true
            }
        }
        if removed {
            rebuildFoldVisibility()
            refresh()
        }
    }

    /// 业务作用：折叠边栏与行号、书签分开命中，标题标记直接反映本视图的收起状态。
    /// 参数说明:
    /// - line: 当前可见真实行。
    /// 返回：只绘制具有完整多行证据的加减标记和收起边界。
    func drawFoldMarker(line: Int) {
        guard let region = folds.index?.region(at: line), region.startLine == line, composition == nil else {
            return
        }
        let rect = NSRect(
            x: visibleRect.minX + gutterWidth - 15,
            y: projection.y(of: line) + 11,
            width: 10,
            height: 10
        )
        let outline = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        themeColor(.foldMarker, fallback: .secondaryLabelColor).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let marks = NSBezierPath()
        marks.move(to: NSPoint(x: rect.minX + 2, y: rect.midY))
        marks.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
        if folds.collapsed.contains(region.range) {
            marks.move(to: NSPoint(x: rect.midX, y: rect.minY + 2))
            marks.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
            marks.move(to: NSPoint(x: visibleRect.minX + gutterWidth, y: projection.y(of: line + 1) + 7))
            marks.line(to: NSPoint(x: visibleRect.maxX, y: projection.y(of: line + 1) + 7))
        }
        marks.stroke()
    }
}
