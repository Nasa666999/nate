import AppKit
import NateCore
import NateSyntax

@MainActor
struct EditorReferenceGuideFrame {
    var planner: IndentationGuidePlanner
    var remaining: Duration
}

extension EditorView {
    /// 业务作用：同帧参考线共享八毫秒和有界前导读取，只借用当前已经发布的折叠开端。
    /// 参数说明: 无。
    /// 返回：参考线开启时的同源规划状态；关闭或初始化失败时不参与后续行绘制。
    func referenceGuideFrame() -> EditorReferenceGuideFrame? {
        guard showIndentGuides else {
            return nil
        }
        let source = DocumentSnapshot(id: document.id, revision: document.revision, text: displayTree)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let index: FoldIndex?
        if composition == nil, folds.context == brackets.context,
            folds.index?.documentID == source.id, folds.index?.revision == source.revision
        {
            index = folds.index
        }
        else {
            // 候选投影或旧折叠不拥有当前行号证据，空行仍可采用当前原文的前导信息。
            index = nil
        }
        let forward = [
            "python", "coffeescript", "haskell", "c", "cpp", "objc", "cs", "java", "php",
            "javascript", "javascript.js", "makefile", "asn1", "gdscript",
        ].contains(language?.id ?? "")
        do {
            let planner = try IndentationGuidePlanner(
                snapshot: source,
                tabWidth: tabSettings.width,
                forwardOnly: forward,
                isFoldHeader: {
                    line in
                    guard let index else {
                        return false
                    }
                    var lower = 0, upper = index.regions.count
                    while lower < upper {
                        let middle = lower + (upper - lower) / 2
                        if index.regions[middle].startLine < line {
                            lower = middle + 1
                        }
                        else {
                            upper = middle
                        }
                    }
                    return lower < index.regions.count && index.regions[lower].startLine == line
                },
                deadline: deadline
            )
            return EditorReferenceGuideFrame(planner: planner, remaining: .milliseconds(8))
        }
        catch {
            referenceGuideStatus = error.localizedDescription
            return nil
        }
    }

    /// 业务作用：缩进锚点沿实际字形和 Tab 边缘落位，空行虚拟参考线不补写空白或移动正文选择。
    /// 参数说明:
    /// - layout: 当前行已经完成原生排版的有限范围。
    /// - line: 当前显示树中的真实逻辑行。
    /// - y: 当前行在本视图中的实际纵坐标。
    /// - frame: 本帧共享的读取、参考线与时间预算。
    /// - context: 当前同源绘图上下文。
    /// 返回：只在首个视觉行和正文视口内绘制完整参考线；超量时暂停后续参考线并保留正文。
    func drawIndentationGuides(
        in layout: LineLayout,
        line: Int,
        y: CGFloat,
        frame: inout EditorReferenceGuideFrame?,
        context: CGContext
    ) {
        let started = ContinuousClock.now
        defer {
            if let remaining = frame?.remaining {
                frame?.remaining = max(.zero, remaining - (ContinuousClock.now - started))
            }
        }
        do {
            guard let remaining = frame?.remaining else {
                return
            }
            let deadline = started.advanced(by: remaining)
            guard let plan = try frame?.planner.prepare(line: line, deadline: deadline), !plan.anchors.isEmpty
            else {
                return
            }
            let scale = max(1, window?.backingScaleFactor ?? 1)
            let body = referenceGuideBody
            let visible = layout.visibleByteRanges(
                in: body.offsetBy(dx: -gutterWidth, dy: -y).insetBy(dx: -2, dy: 0)
            )
            let path = CGMutablePath()
            var cachedCaret: (Int, NSRect)?
            for (position, anchor) in plan.anchors.enumerated() {
                if position & 7 == 0, ContinuousClock.now >= deadline {
                    throw NateError.message("参考线字形定位超过当前帧截止，后续参考线暂停，正文保持。")
                }
                guard anchor.byteOffset >= layout.renderedRange.lower,
                    anchor.byteOffset <= layout.renderedRange.upper,
                    let offset = displayTree.utf16Offset(byte: anchor.byteOffset)
                else {
                    continue
                }
                if anchor.virtualColumns == 0, !layout.range.isEmpty,
                    !visible.contains(where: {
                        anchor.byteOffset >= $0.lower && anchor.byteOffset <= $0.upper
                    })
                {
                    continue
                }
                let caret: NSRect
                if let previous = cachedCaret, previous.0 == offset {
                    caret = previous.1
                }
                else {
                    caret = layout.caret(at: offset - layout.originUTF16)
                    cachedCaret = (offset, caret)
                }
                guard caret.minY < 0.5 else {
                    continue
                }
                let virtual = CGFloat(anchor.virtualColumns) * CGFloat(layout.virtualColumnWidth)
                let x = gutterWidth + caret.minX + (rtl ? -virtual : virtual)
                let origin = gutterWidth + (rtl ? nativeBodyLayoutWidth : 0)
                if plan.isBlank, abs(x - origin) >= 100_000 {
                    continue
                }
                guard x.isFinite, x >= body.minX, x < body.maxX else {
                    continue
                }
                let aligned = (x * scale).rounded() / scale + 0.5 / scale
                let top = max(body.minY, y)
                let height = wrapLines ? min(caret.height, layout.height) : lineHeight
                let bottom = min(body.maxY, y + height)
                if top < bottom {
                    path.move(to: CGPoint(x: aligned, y: top))
                    path.addLine(to: CGPoint(x: aligned, y: bottom))
                }
            }
            context.saveGState()
            context.clip(to: body)
            context.setStrokeColor(themeColor(.indentGuide, fallback: .separatorColor).cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(
                phase: y.truncatingRemainder(dividingBy: 2 / scale),
                lengths: [1 / scale, 1 / scale]
            )
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
        catch {
            // 未完成的定位不进入当前行路径，后续行也不再沿耗尽或过期的共同预算继续读取。
            frame = nil
            referenceGuideStatus = error.localizedDescription
        }
    }

    /// 业务作用：长行参考列按当前默认正文空格宽度定位，缩放、方向和主题变更只改变显示坐标。
    /// 参数说明:
    /// - drawing: 当前系统要求重绘的可见区域。
    /// 返回：合法开启时绘制一条物理像素参考线，不插入换行、不改变文件宽度或选择。
    func drawLongLineGuide(in drawing: NSRect) {
        guard let column = longLineColumn, (1...4096).contains(column) else {
            return
        }
        let advance = NSAttributedString(
            string: " ",
            attributes: [.font: defaultVirtualSpaceFont]
        ).size().width
        let offset = CGFloat(column) * max(1, advance)
        let x = gutterWidth + (rtl ? nativeBodyLayoutWidth - offset : offset)
        let body = drawing.intersection(referenceGuideBody)
        guard !body.isNull, x.isFinite, x >= body.minX, x < body.maxX else {
            return
        }
        let scale = max(1, window?.backingScaleFactor ?? 1)
        themeColor(.longLineGuide, fallback: .separatorColor).setFill()
        NSRect(
            x: (x * scale).rounded() / scale,
            y: body.minY,
            width: 1 / scale,
            height: body.height
        ).fill()
    }

    /// 业务作用：参考线只能覆盖当前可见正文，横向滚动后的固定边栏仍保留自己的绘制范围。
    /// 参数说明: 无。
    /// 返回：排除固定边栏后的有限视口矩形，不移动滚动位置。
    private var referenceGuideBody: NSRect {
        var body = visibleRect
        body.origin.x += gutterWidth
        body.size.width = max(0, body.width - gutterWidth)
        return body
    }
}
