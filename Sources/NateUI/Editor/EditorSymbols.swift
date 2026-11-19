import AppKit
import NateCore

extension EditorView {
    /// 业务作用：不可见字符只读取实际原生投影，软换行标记跟随字形位置，显示开关不改写正文。
    /// 参数说明:
    /// - layout: 当前行的完整原生段落或有界窗口。
    /// - y: 当前真实行的视图纵坐标。
    /// 返回：可见空格、Tab 与真实行尾标记；窗口边界不伪造成逻辑行终止。
    func drawSymbols(layout: LineLayout, y: CGFloat) {
        let displayed = layout.renderedRange
        let text = displayTree.text(in: displayed)
        var offset =
            (displayTree.utf16Offset(byte: displayed.lower) ?? layout.originUTF16) - layout.originUTF16
        for ch in text {
            if ch == " " || ch == "\t" {
                let position = layout.caret(at: offset)
                let marker = NSRect(
                    x: gutterWidth + position.minX,
                    y: y + position.minY,
                    width: max(1, font.maximumAdvancement.width),
                    height: max(lineHeight, position.height)
                )
                if visibleRect.intersects(marker) {
                    NSAttributedString(
                        string: ch == " " ? "·" : "→",
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor.tertiaryLabelColor,
                        ]
                    ).draw(at: marker.origin)
                }
            }
            offset += ch.utf16.count
        }
        guard displayed.upper == layout.range.upper else {
            return
        }
        let end = layout.caret(at: offset)
        NSAttributedString(
            string: "¬",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ).draw(
            at: NSPoint(
                x: gutterWidth + end.minX,
                y: y + end.minY
            )
        )
    }
}
