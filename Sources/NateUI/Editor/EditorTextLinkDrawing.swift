import AppKit
import NateCore

@MainActor
struct EditorTextLinkFrame {
    let snapshot: DocumentSnapshot
    let settings: TextLinkSettings
    var remaining: Duration = .milliseconds(8)
    var rectangles = 4096
}

extension EditorView {
    /// 业务作用：当前帧链接呈现固定同一正文与设置，组合输入不沿提交正文坐标绘制链接。
    /// 参数说明: 无。
    /// 返回：开启且来源完整时的共同预算，尚无完整页或候选输入期间为空。
    func textLinkFrame() -> EditorTextLinkFrame? {
        guard textLinkSettings.mode != .disabled, composition == nil, !textLinks.pages.isEmpty else {
            return nil
        }
        return EditorTextLinkFrame(snapshot: document.snapshot, settings: textLinkSettings)
    }

    /// 业务作用：链接采用实际当前字形的非空交集，不在未排版范围估算点击或提示位置。
    /// 参数说明:
    /// - link: 当前页已经完整验证的链接。
    /// - layout: 当前来源的实际原生行布局。
    /// 返回：当前已排版部分对应的真实选择矩形，没有字形证据时为空。
    func textLinkRects(_ link: DocumentTextLink, in layout: LineLayout) -> [CGRect] {
        guard layout.unavailableReason == nil else {
            return []
        }
        let lower = max(link.range.lower, layout.renderedRange.lower)
        let upper = min(link.range.upper, layout.renderedRange.upper)
        guard lower < upper else {
            return []
        }
        return layout.selectionRects(ByteRange(lower, upper))
    }

    /// 业务作用：按已排序原字节范围跳过屏幕外链接，远处水平视口不逐项定位整行的所有目标。
    /// 参数说明:
    /// - page: 当前来源完整的固定链接页。
    /// - layout: 当前实际排版及已呈现原文范围。
    /// 返回：与已排版范围相交的原顺序链接切片，固定页面保持不变。
    func visibleTextLinks(in page: DocumentTextLinkPage, layout: LineLayout) -> ArraySlice<DocumentTextLink> {
        var lower = 0
        var upper = page.links.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if page.links[middle].range.upper <= layout.renderedRange.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        upper = lower
        while upper < page.links.count, page.links[upper].range.lower < layout.renderedRange.upper {
            upper += 1
        }
        return page.links[lower..<upper]
    }

    /// 业务作用：链接下划线及悬停前景沿当前实际字形绘制，选择前景可在后续正常绘制中继续覆盖。
    /// 参数说明:
    /// - layout: 当前来源的完整可用排版。
    /// - line: 当前真实逻辑行。
    /// - y: 当前行在视图中的实际纵坐标。
    /// - frame: 同帧来源、时间与矩形共同余量。
    /// - context: 当前原生绘制上下文。
    /// 返回：整行几何完整时显示链接指示；超量暂停链接呈现，不改变正文或选择。
    func drawTextLinkIndicators(
        in layout: LineLayout,
        line: Int,
        y: CGFloat,
        frame: inout EditorTextLinkFrame?,
        context: CGContext
    ) {
        guard let source = frame, let page = textLinks.pages[line],
            page.matches(source.snapshot, settings: source.settings)
        else {
            return
        }
        let mode = source.settings.mode
        let underlined = mode == .underlinedForeground || mode == .underlinedBackground
        let recolored = mode == .underlinedForeground || mode == .foregroundOnHover
        guard underlined || recolored && textLinks.hovered != nil else {
            return
        }
        let started = ContinuousClock.now
        defer {
            frame?.remaining -= ContinuousClock.now - started
        }
        let deadline = started.advanced(by: max(.zero, source.remaining))
        let scale = max(1, window?.backingScaleFactor ?? 1)
        let path = CGMutablePath()
        var hoveredRects: [CGRect] = []
        var remaining = source.rectangles
        for link in visibleTextLinks(in: page, layout: layout) {
            guard ContinuousClock.now < deadline else {
                frame = nil
                textLinks.status = "链接字形指示超过当前帧计算截止，正文保持。"
                return
            }
            let rects = textLinkRects(link, in: layout)
            guard rects.count <= remaining else {
                frame = nil
                textLinks.status = "链接指示超过当前帧 4096 个矩形，正文保持。"
                return
            }
            remaining -= rects.count
            if underlined {
                for rect in rects {
                    path.move(to: CGPoint(x: gutterWidth + rect.minX, y: y + rect.maxY - 1 / scale))
                    path.addLine(to: CGPoint(x: gutterWidth + rect.maxX, y: y + rect.maxY - 1 / scale))
                }
            }
            if recolored, let hover = textLinks.hovered, hover.link == link,
                hover.page.matches(source.snapshot, settings: source.settings)
            {
                hoveredRects = rects
            }
        }
        guard ContinuousClock.now < deadline else {
            frame = nil
            textLinks.status = "链接呈现超过当前帧计算截止，正文保持。"
            return
        }
        context.saveGState()
        context.clip(to: textLinkBodyRect())
        if underlined {
            themeColor(.foreground, fallback: .textColor).setStroke()
            context.setLineWidth(1 / scale)
            context.addPath(path)
            context.strokePath()
        }
        if !hoveredRects.isEmpty {
            context.saveGState()
            context.addRects(
                hoveredRects.map {
                    $0.offsetBy(dx: gutterWidth, dy: y)
                }
            )
            context.clip()
            layout.drawForeground(
                at: NSPoint(x: gutterWidth, y: y),
                color: themeColor(.linkForeground, fallback: .systemBlue),
                in: context
            )
            context.restoreGState()
        }
        context.restoreGState()
        frame?.rectangles = remaining
    }

    /// 业务作用：背景提示只着色悬停链接的实际字形范围，选区与正文仍由正常绘制次序呈现。
    /// 参数说明:
    /// - layout: 当前完整原生排版。
    /// - line: 当前真实逻辑行。
    /// - y: 该行在视图中的实际纵坐标。
    /// - frame: 本帧共同来源和绘制预算。
    /// - context: 当前原生绘制上下文。
    /// 返回：背景模式使用链接颜色的半透明提示，超量只暂停链接呈现并保留正文。
    func drawTextLinkBackground(
        in layout: LineLayout,
        line: Int,
        y: CGFloat,
        frame: inout EditorTextLinkFrame?,
        context: CGContext
    ) {
        guard let source = frame,
            source.settings.mode == .underlinedBackground || source.settings.mode == .backgroundOnHover,
            let hover = textLinks.hovered, let page = textLinks.pages[line],
            page.matches(source.snapshot, settings: source.settings),
            hover.page.matches(source.snapshot, settings: source.settings),
            page.link(containing: hover.link.range.lower) == hover.link
        else {
            return
        }
        let started = ContinuousClock.now
        defer {
            frame?.remaining -= ContinuousClock.now - started
        }
        guard source.remaining > .zero else {
            frame = nil
            return
        }
        let rects = textLinkRects(hover.link, in: layout)
        guard rects.count <= source.rectangles, ContinuousClock.now - started < source.remaining else {
            frame = nil
            textLinks.status = "链接背景提示超过当前帧预算，正文保持。"
            return
        }
        context.saveGState()
        context.clip(to: textLinkBodyRect())
        themeColor(.linkForeground, fallback: .systemBlue).withAlphaComponent(0.2).setFill()
        for rect in rects {
            rect.offsetBy(dx: gutterWidth, dy: y).fill()
        }
        context.restoreGState()
        frame?.rectangles -= rects.count
    }

    /// 业务作用：水平滚动时链接绘制始终排除固定边栏，不能用正文提示覆盖书签或折叠区域。
    /// 参数说明: 无。
    /// 返回：当前视口去掉固定边栏后的正文裁剪矩形。
    func textLinkBodyRect() -> CGRect {
        var rect = visibleRect
        rect.origin.x += gutterWidth
        rect.size.width = max(0, rect.width - gutterWidth)
        return rect
    }
}
