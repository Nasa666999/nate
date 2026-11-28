import AppKit
import NateCore

extension LineLayout {
    /// 业务作用：语法背景先于当前行、标记及选择绘制，完整字形仍交给原生文本引擎。
    /// 参数说明:
    /// - origin: 当前逻辑行在编辑视图中的实际起点。
    /// - context: 当前视图的绘制上下文。
    /// - budget: 本帧所有颜色和高亮共用的剩余绘制数量。
    /// 返回：全部可见背景绘制完成时为真；密度超限时停止背景，正文与完整样式继续保留。
    func drawSyntaxBackgrounds(at origin: NSPoint, in context: CGContext, budget: inout Int) -> Bool {
        guard unavailableReason == nil, !syntaxBackgrounds.isEmpty else {
            return true
        }
        let clip = context.boundingBoxOfClipPath.offsetBy(dx: -origin.x, dy: -origin.y)
        guard !clip.isNull, clip.minX.isFinite, clip.maxX.isFinite,
            clip.minY.isFinite, clip.maxY.isFinite
        else {
            return true
        }
        context.saveGState()
        defer {
            context.restoreGState()
        }
        let visible = visibleByteRanges(in: clip)
        for background in syntaxBackgrounds {
            for scope in visible {
                let lower = max(background.range.lower, scope.lower)
                let upper = min(background.range.upper, scope.upper)
                guard upper > lower else {
                    continue
                }
                guard budget > 0 else {
                    return false
                }
                budget -= 1
                context.setFillColor(background.color.cgColor)
                // 原生视觉分段同时保留软换行和双向字形范围，不能用首尾光标拼一个跨行矩形。
                let tree = content.snapshot.text
                guard let start = tree.utf16Offset(byte: lower), let end = tree.utf16Offset(byte: upper),
                    let selected = NSTextRange(
                        location: EditorTextLocation(
                            documentID: content.snapshot.id,
                            revision: content.snapshot.revision,
                            offset: start
                        ),
                        end: EditorTextLocation(
                            documentID: content.snapshot.id,
                            revision: content.snapshot.revision,
                            offset: end
                        )
                    )
                else {
                    return false
                }
                var complete = true
                manager.enumerateTextSegments(in: selected, type: .selection, options: [.rangeNotRequired]) {
                    _,
                    nativeRectangle,
                    _,
                    _ in
                    guard budget > 0 else {
                        complete = false
                        return false
                    }
                    budget -= 1
                    let rectangle = nativeRectangle.offsetBy(dx: horizontalShift, dy: 0)
                    if rectangle.intersects(clip)
                        || background.fillsLineEnd && rectangle.maxY > clip.minY && rectangle.minY < clip.maxY
                    {
                        var painted = rectangle
                        if background.fillsLineEnd {
                            // 整行节底色不依赖文字方向或当前水平滚动，正文区两端都保持同一背景。
                            painted.origin.x = max(0, clip.minX)
                            painted.size.width = max(0, clip.maxX - painted.minX)
                        }
                        context.fill(painted.offsetBy(dx: origin.x, dy: origin.y))
                    }
                    return true
                }
                if !complete {
                    return false
                }
            }
        }
        return true
    }
}

extension EditorView {
    /// 业务作用：把当前段落的语法背景纳入本帧绘制顺序和统一密度反馈。
    /// 参数说明:
    /// - layout: 当前固定正文与外观的原生排版。
    /// - y: 真实逻辑行在编辑区中的纵向起点。
    /// - context: 当前绘制上下文。
    /// - budget: 本帧所有颜色与标记共用的剩余数量。
    /// 返回：可见背景先行绘制；超限只反馈呈现密度，不修改完整样式或原文。
    func drawSyntaxBackgrounds(in layout: LineLayout, y: CGFloat, context: CGContext, budget: inout Int) {
        if !layout.drawSyntaxBackgrounds(
            at: NSPoint(
                x: gutterWidth,
                y: y
            ),
            in: context,
            budget: &budget
        ) {
            textHighlightDisplayStatus = "当前帧语法背景超过绘制预算，完整正文与样式索引保持原状。"
        }
    }
}
