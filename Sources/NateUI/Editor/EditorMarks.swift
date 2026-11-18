import AppKit
import NateCore

extension EditorView {
    /// 业务作用：持久颜色单独绘制在正文与选区下方，语法色、括号和输入法覆盖层保持独立。
    /// 参数说明:
    /// - layout: 当前真实逻辑行的 TextKit 布局。
    /// - line: 当前已提交正文中的逻辑行号。
    /// - y: 本行在视图内的垂直位置。
    /// - budget: 整帧共享的标记与矩形绘制余额。
    /// 返回：有界可见颜色进入背景，密度超限保留全部标记数据并提供状态；预编辑期间不误用已提交偏移。
    func drawDocumentMarks(in layout: LineLayout, line: Int, y: CGFloat, budget: inout Int) {
        // 预编辑采用独立展示坐标，不能将已提交正文的颜色偏移直接套入候选；数据保留到组合结束后重绘。
        guard composition == nil, document.marks.count > 0, markDisplayStatus == nil else {
            return
        }
        do {
            let lineRange = document.text.lineRange(line)
            for style in DocumentMarkStyle.allCases {
                // 可见范围和矩形共用整帧余额，过密背景不能占满事件循环而阻塞正文输入。
                let ranges = try document.marks.displayRanges(
                    for: style,
                    intersecting: lineRange,
                    limit: budget
                )
                for range in ranges {
                    if range.isEmpty && document.text.lineNumber(at: range.lower) != line {
                        continue
                    }
                    let lower = max(range.lower, layout.range.lower)
                    let upper = min(range.upper, layout.range.upper)
                    let color = markColor(style)
                    if lower < upper {
                        color.withAlphaComponent(0.28).setFill()
                        for rect in layout.selectionRects(ByteRange(lower, upper)) {
                            guard budget > 0 else {
                                throw NateError.message("可见颜色标记过密，当前帧部分背景未绘制；标记数据保留。")
                            }
                            budget -= 1
                            rect.offsetBy(dx: gutterWidth, dy: y).fill()
                        }
                    }
                    else if range.isEmpty || range.lower < lineRange.upper && range.upper > layout.range.upper
                    {
                        guard budget > 0 else {
                            throw NateError.message("可见颜色标记过密，当前帧部分背景未绘制；标记数据保留。")
                        }
                        budget -= 1
                        let offset = min(max(range.lower, layout.range.lower), layout.range.upper)
                        if let utf16 = document.text.utf16Offset(byte: offset) {
                            let caret = layout.caret(at: utf16 - layout.originUTF16)
                            color.withAlphaComponent(0.8).setFill()
                            NSRect(
                                x: gutterWidth + caret.minX,
                                y: y + caret.minY,
                                width: 3,
                                height: max(caret.height, lineHeight)
                            ).fill()
                        }
                    }
                }
            }
        }
        catch {
            markDisplayStatus = error.localizedDescription
        }
    }

    /// 业务作用：查找与五组样式使用独立背景色，不覆盖语言词法的前景与字体属性。
    /// 参数说明:
    /// - style: 当前持久颜色组。
    /// 返回：随系统外观解析的语义颜色。
    func markColor(_ style: DocumentMarkStyle) -> NSColor {
        switch style {
        case .search: .systemOrange
        case .style1: .systemYellow
        case .style2: .systemGreen
        case .style3: .systemBlue
        case .style4: .systemPurple
        case .style5: .systemPink
        }
    }
}
