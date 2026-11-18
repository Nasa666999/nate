import AppKit
import NateCore

public enum TextHighlightLayer: Sendable, CaseIterable, Hashable {
    case incremental
    case selectedText
}

extension EditorView {
    /// 业务作用：视图临时高亮只接受当前正文的完整索引，不占用文档的查找颜色或五组样式。
    /// 参数说明:
    /// - highlights: 后台完成的高亮索引，空值表示清除该临时图层。
    /// - layer: 增量查找或选中文本的独立图层。
    /// 返回：修订与文档身份一致时替换图层并重绘，过期索引不改变当前图层。
    @discardableResult
    public func setTextHighlights(_ highlights: PreparedTextHighlights?, for layer: TextHighlightLayer)
        -> Bool
    {
        if let highlights {
            // 不将旧正文的范围夹断到新正文，正文修订改变后必须重新匹配。
            guard highlights.documentID == document.id, highlights.revision == document.revision else {
                return false
            }
        }
        textHighlights[layer] = highlights
        needsDisplay = true
        return true
    }

    /// 业务作用：提供当前视图独立高亮的完整匹配位置，其他视图与文档持久标记保持独立。
    /// 参数说明:
    /// - layer: 需要观察的临时图层。
    /// 返回：只返回当前文档修订的范围，尚无索引或已经失效时为空。
    public func textHighlightRanges(for layer: TextHighlightLayer) -> [ByteRange] {
        guard let value = textHighlights[layer], value.documentID == document.id,
            value.revision == document.revision
        else {
            return []
        }
        return value.ranges
    }

    /// 业务作用：临时匹配使用独立描边背景，不覆盖语法前景，也不写入用户持久颜色集合。
    /// 参数说明:
    /// - layout: 当前可见逻辑行的 TextKit 布局。
    /// - line: 当前正文逻辑行。
    /// - y: 当前行的视图纵向位置。
    /// - budget: 持久与临时图层共享的整帧绘制余额。
    /// 返回：只绘制有界的有效范围，候选期间暂停；过密时保留索引并报告未完整绘制。
    func drawTextHighlights(in layout: LineLayout, line: Int, y: CGFloat, budget: inout Int) {
        // 预编辑正文不使用已提交正文的偏移，组合结束后才恢复临时高亮。
        guard composition == nil, textHighlightDisplayStatus == nil else {
            return
        }
        do {
            let row = document.text.lineRange(line)
            for layer in TextHighlightLayer.allCases {
                guard let value = textHighlights[layer], value.documentID == document.id,
                    value.revision == document.revision
                else {
                    continue
                }
                let color: NSColor = layer == .incremental ? .systemTeal : .systemGreen
                for range in try value.displayRanges(intersecting: row, limit: budget) {
                    if range.isEmpty && document.text.lineNumber(at: range.lower) != line {
                        continue
                    }
                    let lower = max(range.lower, layout.range.lower)
                    let upper = min(range.upper, layout.range.upper)
                    var rectangles: [NSRect] = []
                    if lower < upper {
                        rectangles = layout.selectionRects(ByteRange(lower, upper))
                    }
                    else if range.isEmpty || range.lower < row.upper && range.upper > layout.range.upper,
                        let offset = document.text.utf16Offset(
                            byte: min(max(range.lower, layout.range.lower), layout.range.upper)
                        )
                    {
                        let caret = layout.caret(at: offset - layout.originUTF16)
                        rectangles = [
                            NSRect(
                                x: caret.minX,
                                y: caret.minY,
                                width: 3,
                                height: max(caret.height, lineHeight)
                            )
                        ]
                    }
                    for rectangle in rectangles {
                        guard budget > 0 else {
                            throw NateError.message("可见临时高亮过密，当前帧未完整绘制；匹配索引保留。")
                        }
                        budget -= 1
                        let rectangle = rectangle.offsetBy(dx: gutterWidth, dy: y)
                        color.withAlphaComponent(0.12).setFill()
                        rectangle.fill()
                        color.withAlphaComponent(0.85).setStroke()
                        let border = NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5))
                        border.lineWidth = 1
                        border.stroke()
                    }
                }
            }
        }
        catch {
            textHighlightDisplayStatus = error.localizedDescription
        }
    }
}
