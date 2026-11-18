import AppKit
import NateCore
import NateSyntax

@MainActor
final class LineLayout {
    let manager: NSTextLayoutManager
    let content: EditorContentManager
    let range: ByteRange
    let originUTF16: Int
    var fragments: [NSTextLayoutFragment] = []
    var height: CGFloat = 20
    var width: CGFloat = 0

    /// 业务作用：只为当前可见段落建立原生字形、双向排版和命中映射。
    /// 参数说明:
    /// - snapshot: 正文快照。
    /// - range: 完整逻辑行范围。
    /// - font: 当前视图字体。
    /// - width: 排版宽度。
    /// - tokens: 当前快照语法呈现。
    /// - rtl: 段落基础方向。
    /// - appearance: 所属视图的实际外观，布局可能发生在绘制回调之外。
    /// 返回：只读 TextKit 2 布局缓存，控制字符只在呈现副本中使用等长占位，原文与坐标保持一致。
    init(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        width: CGFloat,
        tokens: [SyntaxToken],
        rtl: Bool,
        appearance: NSAppearance
    ) {
        self.range = range
        originUTF16 = snapshot.text.utf16Offset(byte: range.lower) ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.defaultTabInterval = font.maximumAdvancement.width * 4
        paragraph.tabStops = []
        let value = NSMutableAttributedString(
            string: LineControlPresentation.render(snapshot.text.text(in: range)),
            attributes: [
                .font: font, .foregroundColor: ThemePalette.resolved(.textColor, appearance: appearance),
                .paragraphStyle: paragraph,
            ]
        )
        for token in tokens where token.range.lower < range.upper && token.range.upper > range.lower {
            let clipped = ByteRange(max(range.lower, token.range.lower), min(range.upper, token.range.upper))
            if let ns = snapshot.text.nsRange(clipped) {
                value.addAttribute(
                    .foregroundColor,
                    value: ThemePalette.resolved(
                        token.foreground.flatMap(ThemePalette.hexColor) ?? ThemePalette.color(token.kind),
                        appearance: appearance
                    ),
                    range: NSRange(location: ns.location - originUTF16, length: ns.length)
                )
                let tokenRange = NSRange(location: ns.location - originUTF16, length: ns.length)
                var styledFont = font
                if token.fontStyle & 1 != 0 {
                    styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask)
                }
                if token.fontStyle & 2 != 0 {
                    styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask)
                }
                value.addAttribute(.font, value: styledFont, range: tokenRange)
                if token.fontStyle & 4 != 0 {
                    value.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: tokenRange
                    )
                }
            }
        }
        content = EditorContentManager(snapshot: snapshot, projection: range, rendered: value)
        manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        // 光标导航也会提前建立布局，不能依赖 drawRect 才自动设置的线程绘制外观。
        appearance.performAsCurrentDrawingAppearance {
            manager.ensureLayout(for: content.documentRange)
            manager.enumerateTextLayoutFragments(
                from: content.documentRange.location,
                options: [.ensuresLayout]
            ) {
                fragment in
                self.fragments.append(fragment)
                self.height = max(self.height, fragment.layoutFragmentFrame.maxY)
                self.width = max(self.width, fragment.layoutFragmentFrame.maxX)
                return false
            }
        }
    }

    /// 业务作用：通过原生字形映射像素到 UTF-16，避免按字符宽度猜测中文和 Emoji。
    /// 参数说明:
    /// - point: 段落内像素位置。
    /// 返回：段落内系统字符位置。
    func character(at point: NSPoint) -> Int {
        for fragment in fragments {
            for line in fragment.textLineFragments {
                let box = line.typographicBounds.offsetBy(
                    dx: fragment.layoutFragmentFrame.minX,
                    dy: fragment.layoutFragmentFrame.minY
                )
                if point.y < box.maxY {
                    return line.characterIndex(for: NSPoint(x: point.x - box.minX, y: point.y - box.minY))
                }
            }
        }
        return content.rendered.length
    }

    /// 业务作用：通过 TextKit 选区片段查询光标与候选框位置。
    /// 参数说明:
    /// - local: 段落内 UTF-16 位置。
    /// 返回：段落内光标矩形。
    func caret(at local: Int) -> NSRect {
        for fragment in fragments {
            for line in fragment.textLineFragments {
                let range = line.characterRange
                if local >= range.location && local <= range.location + range.length {
                    let p = line.locationForCharacter(at: local)
                    return NSRect(
                        x: p.x + fragment.layoutFragmentFrame.minX,
                        y: line.typographicBounds.minY + fragment.layoutFragmentFrame.minY,
                        width: 1.5,
                        height: line.typographicBounds.height
                    )
                }
            }
        }
        return NSRect(x: 0, y: 0, width: 1.5, height: height)
    }

    /// 业务作用：让软换行与双向文字选区按原生字形片段绘制。
    /// 参数说明:
    /// - range: 本段落内的真实字节选区。
    /// 返回：可能包含多个方向和视觉行的呈现矩形。
    func selectionRects(_ range: ByteRange) -> [NSRect] {
        guard !range.isEmpty, range.lower >= self.range.lower, range.upper <= self.range.upper,
            let a = content.snapshot.text.utf16Offset(byte: range.lower),
            let b = content.snapshot.text.utf16Offset(byte: range.upper),
            let selected = NSTextRange(
                location: EditorTextLocation(
                    documentID: content.snapshot.id,
                    revision: content.snapshot.revision,
                    offset: a
                ),
                end: EditorTextLocation(
                    documentID: content.snapshot.id,
                    revision: content.snapshot.revision,
                    offset: b
                )
            )
        else {
            return []
        }
        var result: [NSRect] = []
        manager.enumerateTextSegments(in: selected, type: .selection, options: [.rangeNotRequired]) {
            _,
            rect,
            _,
            _ in
            result.append(rect)
            return true
        }
        return result
    }
}

@MainActor
enum ThemePalette {
    /// 业务作用：提前排版时按真实视图外观解析动态颜色，缓存不携带其他窗口的深浅状态。
    /// 参数说明:
    /// - color: 系统或资源颜色。
    /// - appearance: 所属编辑视图的外观。
    /// 返回：已经在目标外观中解析的 RGB 颜色。
    static func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// 业务作用：语法样式跟随系统深浅主题，与正文状态独立。
    /// 参数说明:
    /// - kind: 语法分类。
    /// 返回：可辨识的系统适配颜色。
    static func color(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPurple
        case .string: return .systemGreen
        case .comment: return .secondaryLabelColor
        case .number: return .systemBlue
        case .heading: return .systemBlue
        case .tag: return .systemTeal
        case .punctuation: return .secondaryLabelColor
        case .text: return .textColor
        }
    }

    /// 业务作用：资源颜色只作为呈现值使用，非法格式继承主题。
    /// 参数说明:
    /// - hex: 六位 RGB 资源色。
    /// 返回：有效颜色或继承状态。
    static func hexColor(_ hex: String) -> NSColor? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1
        )
    }
}
