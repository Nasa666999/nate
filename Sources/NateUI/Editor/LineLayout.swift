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
    /// 返回：只读 TextKit 2 布局缓存。
    init(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        width: CGFloat,
        tokens: [SyntaxToken],
        rtl: Bool
    ) {
        self.range = range
        originUTF16 = snapshot.text.utf16Offset(byte: range.lower) ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.defaultTabInterval = font.maximumAdvancement.width * 4
        paragraph.tabStops = []
        let value = NSMutableAttributedString(
            string: snapshot.text.text(in: range),
            attributes: [
                .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
            ]
        )
        for token in tokens where token.range.lower >= range.lower && token.range.upper <= range.upper {
            if let ns = snapshot.text.nsRange(token.range) {
                value.addAttribute(
                    .foregroundColor,
                    value: ThemePalette.color(token.kind),
                    range: NSRange(location: ns.location - originUTF16, length: ns.length)
                )
            }
        }
        content = EditorContentManager(snapshot: snapshot, projection: range, rendered: value)
        manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: content.documentRange)
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout])
        {
            fragment in
            self.fragments.append(fragment)
            self.height = max(self.height, fragment.layoutFragmentFrame.maxY)
            self.width = max(self.width, fragment.layoutFragmentFrame.maxX)
            return false
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
}

@MainActor
enum ThemePalette {
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
        }
    }
}
