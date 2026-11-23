import AppKit
import NateCore

extension EditorView {
    /// 业务作用：绘制视口内正文、独立颜色标记、选区、行号、书签和输入法覆盖层。
    /// 参数说明:
    /// - dirtyRect: 系统要求重绘的区域。
    /// 返回：呈现当前已提交快照及独立预编辑，不改动文档。
    public override func draw(_ dirtyRect: NSRect) {
        prepareSelectedTextHighlights()
        prepareBracketAnalysis()
        themeColor(.background, fallback: .textBackgroundColor).setFill()
        dirtyRect.fill()
        let tree = displayTree
        let viewportAnchor = viewportAnchor()
        projection.measurementsChanged = false
        let drawing = dirtyRect.intersection(visibleRect)
        guard !drawing.isNull else {
            return
        }
        let first = projection.line(at: max(0, drawing.minY - 8))
        let last = min(tree.lineCount - 1, projection.line(at: drawing.maxY) + 1)
        guard first <= last, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let active = tree.lineNumber(at: min(primarySelection?.head ?? 0, tree.byteCount))
        let visibleLines = projection.visibleLines(in: first...last)
        var markBudget = 4096
        markDisplayStatus = nil
        textHighlightDisplayStatus = nil
        for line in visibleLines {
            let layout = layoutLine(line)
            let y = projection.y(of: line) + 8
            if layout.unavailableReason != nil {
                layout.draw(at: NSPoint(x: visibleRect.minX + gutterWidth, y: y), in: context)
                continue
            }
            drawSyntaxBackgrounds(in: layout, y: y, context: context, budget: &markBudget)
            if line == active {
                themeColor(
                    .currentLineBackground,
                    fallback: NSColor.controlAccentColor.withAlphaComponent(0.05)
                ).setFill()
                NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight).fill()
            }
            drawDocumentMarks(in: layout, line: line, y: y, budget: &markBudget)
            drawTextHighlights(in: layout, line: line, y: y, budget: &markBudget)
            if !drawRectangularSelection(in: layout, line: line, y: y) {
                for selection in viewSelections where !selection.range.isEmpty && composition == nil {
                    let a = max(selection.range.lower, layout.range.lower)
                    let b = min(selection.range.upper, layout.range.upper)
                    if a <= b {
                        themeColor(
                            .selectionBackground,
                            fallback: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6)
                        ).setFill()
                        for rect in layout.selectionRects(ByteRange(a, b)) {
                            rect.offsetBy(dx: gutterWidth, dy: y).fill()
                        }
                    }
                }
            }
            drawVirtualRectangle(in: layout, line: line, y: y)
            drawBracketMatch(in: layout, y: y)
            layout.draw(at: NSPoint(x: gutterWidth, y: y), in: context)
            drawThemeSelectionForeground(in: layout, y: y, context: context)
            if showSymbols {
                drawSymbols(layout: layout, y: y)
            }
            if composition == nil && caretVisible && window?.firstResponder === self
                && layout.unavailableReason == nil
            {
                for selection in viewSelections where tree.lineNumber(at: selection.head) == line {
                    guard selection.head >= layout.renderedRange.lower,
                        selection.head <= layout.renderedRange.upper
                    else {
                        continue
                    }
                    if let offset = tree.utf16Offset(byte: selection.head) {
                        var rect = layout.caret(at: offset - layout.originUTF16)
                        rect.origin.x += gutterWidth + selectionCaretOffset(for: selection)
                        rect.origin.y += y
                        rect.size.height = max(rect.height, lineHeight)
                        themeColor(.caret, fallback: .controlAccentColor).setFill()
                        rect.fill()
                    }
                }
            }
            if let composition, layout.unavailableReason == nil,
                line == tree.lineNumber(at: composition.originalRange.lower)
            {
                let start = tree.utf16Offset(byte: composition.originalRange.lower) ?? 0
                let caret = layout.caret(
                    at: start - layout.originUTF16 + composition.virtualPadding
                        + composition.selected.location
                )
                themeColor(.caret, fallback: .controlAccentColor).setFill()
                NSRect(
                    x: gutterWidth + caret.minX,
                    y: y + lineHeight - 2,
                    width: max(8, CGFloat(composition.text.count) * font.maximumAdvancement.width),
                    height: 1
                ).fill()
            }
        }
        themeColor(.gutterBackground, fallback: .windowBackgroundColor).setFill()
        NSRect(x: visibleRect.minX, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height)
            .fill()
        for line in visibleLines {
            let number = NSAttributedString(
                string: "\(line + 1)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: max(9, font.pointSize - 2),
                        weight: .regular
                    ),
                    .foregroundColor: themeColor(.lineNumber, fallback: .secondaryLabelColor),
                ]
            )
            number.draw(
                at: NSPoint(
                    x: visibleRect.minX + gutterWidth - 25 - number.size().width,
                    y: projection.y(of: line) + 9
                )
            )
            if document.bookmarks.contains(line) {
                themeColor(.bookmark, fallback: .systemBlue).setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: visibleRect.minX + 4,
                        y: projection.y(of: line) + 12,
                        width: 7,
                        height: 7
                    )
                ).fill()
            }
            if document.modifiedLines.contains(line) {
                themeColor(.modificationUnsaved, fallback: .systemGreen).setFill()
                NSRect(
                    x: visibleRect.minX + gutterWidth - 21,
                    y: projection.y(of: line) + 8,
                    width: 2,
                    height: lineHeight
                ).fill()
            }
            drawFoldMarker(line: line)
        }
        let viewport = enclosingScrollView?.contentSize ?? bounds.size
        let height = max(viewport.height, projection.y(of: tree.lineCount) + 60)
        let contentWidth = layouts.values.reduce(viewport.width) {
            max($0, $1.width + gutterWidth + (wrapLines ? 16 : 20))
        }
        // 换行容器不会拆开所有尾随空格，画布仍需容纳原生证据给出的容器外插入点。
        let width = contentWidth
        if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
            needsDisplay = true
        }
        if projection.measurementsChanged {
            restoreViewportAnchor(viewportAnchor)
            needsDisplay = true
        }
    }

}
