import AppKit
import NateCore

extension DocumentPrintView {
    /// 业务作用：正文样式在独立副本中转换，FF 的可见表示与分页规则互不取得正文修改权。
    /// 参数说明: 无。
    /// 返回：原 UTF-16 坐标不变的完整呈现文字，采用固定字号比例、Tab 与明确颜色方案。
    func styledPrintingText() throws -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source.styled)
        let whole = NSRange(
            location: 0,
            length: result.length
        )
        source.styled.enumerateAttributes(in: whole) {
            attributes,
            range,
            _ in
            let original = attributes[.font] as? NSFont ?? source.baseFont
            let font =
                NSFont(
                    descriptor: original.fontDescriptor,
                    size: original.pointSize * source.settings.fontScale
                ) ?? original
            result.addAttribute(.font, value: font, range: range)
            let paragraph =
                (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.tabStops = []
            paragraph.defaultTabInterval =
                (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(source.tabWidth)
            result.addAttribute(.paragraphStyle, value: paragraph.copy(), range: range)
            let foreground = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB) ?? .black
            result.addAttribute(
                .foregroundColor,
                value: source.settings.color == .blackOnWhite ? NSColor.black : foreground,
                range: range
            )
            if source.settings.color == .blackOnWhite || source.settings.color == .noBackground {
                result.removeAttribute(.backgroundColor, range: range)
            }
            else if let color = attributes[.backgroundColor] as? NSColor {
                result.addAttribute(
                    .backgroundColor,
                    value: color.usingColorSpace(.deviceRGB) ?? .clear,
                    range: range
                )
            }
        }
        let string = result.string as NSString
        var search = whole
        while search.length > 0 {
            let found = string.range(of: "\u{c}", range: search)
            guard found.location != NSNotFound else {
                break
            }
            // 替代表示仍占一个 UTF-16 单元，源行号、样式与实际强制分页位置继续使用原坐标。
            result.replaceCharacters(in: found, with: source.showControls ? "\u{240C}" : "\u{200B}")
            search = NSRange(
                location: NSMaxRange(found),
                length: result.length - NSMaxRange(found)
            )
        }
        return result
    }
}
