import AppKit
import NateCore
import NateSyntax

@MainActor
final class LineLayout {
    private(set) var manager: NSTextLayoutManager
    private(set) var content: EditorContentManager
    let range: ByteRange
    let originUTF16: Int
    var fragments: [NSTextLayoutFragment] = []
    var height: CGFloat = 20
    var width: CGFloat = 0
    private let ascii: ASCIILineWindow?
    private(set) var unavailableReason: String?

    var renderedRange: ByteRange {
        ascii?.renderedRange ?? content.projection
    }
    var characterCount: Int {
        ascii == nil ? content.rendered.length : range.count
    }

    /// 业务作用：只为当前可见段落建立原生字形、双向排版和命中映射。
    /// 参数说明:
    /// - snapshot: 正文快照。
    /// - range: 完整逻辑行范围。
    /// - font: 当前视图字体。
    /// - width: 排版宽度。
    /// - tokens: 当前快照语法呈现。
    /// - rtl: 段落基础方向。
    /// - appearance: 所属视图的实际外观，布局可能发生在绘制回调之外。
    /// - viewport: 不换行时的真实可见正文矩形，省略时保留完整原生段落流程。
    /// - nativeASCII: 已证明独立 ASCII 的有界内部段落，关闭上下文连字与字距调整。
    /// 返回：只读 TextKit 2 布局缓存，控制字符只在呈现副本中使用等长占位，原文与坐标保持一致。
    init(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        width: CGFloat,
        tokens: [SyntaxToken],
        rtl: Bool,
        appearance: NSAppearance,
        viewport: NSRect? = nil,
        nativeASCII: Bool = false
    ) {
        self.range = range
        originUTF16 = snapshot.text.utf16Offset(byte: range.lower) ?? 0
        if !nativeASCII, !rtl, tokens.isEmpty, viewport != nil {
            ascii = ASCIILineWindow(
                snapshot: snapshot,
                range: range,
                font: font,
                appearance: appearance
            )
        }
        else {
            ascii = nil
        }
        if let ascii, let viewport {
            ascii.updateViewport(viewport)
            content = ascii.content
            manager = ascii.manager
            height = ascii.height
            self.width = ascii.width
            return
        }
        // 原生引擎会排完整个段落，缺少安全窗口证据时必须在复制原文之前关闭超预算排版。
        guard range.count <= EditorNativeLayoutPolicy.maximumParagraphBytes else {
            unavailableReason = "此逻辑行超过 1 MiB 原生段落预算，当前字形呈现已暂停；完整正文、历史和保存内容保持原状。"
            content = EditorContentManager(
                snapshot: snapshot,
                projection: ByteRange(range.lower, range.lower),
                rendered: NSAttributedString(string: "")
            )
            manager = NSTextLayoutManager()
            content.addTextLayoutManager(manager)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.defaultTabInterval =
            max(1, NSAttributedString(string: " ", attributes: [.font: font]).size().width) * 4
        paragraph.tabStops = []
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ThemePalette.resolved(.textColor, appearance: appearance),
            .paragraphStyle: paragraph,
        ]
        if nativeASCII {
            attributes[.ligature] = 0
            attributes[.kern] = 0
        }
        let value = NSMutableAttributedString(
            string: LineControlPresentation.render(snapshot.text.text(in: range)),
            attributes: attributes
        )
        for token in tokens where token.range.lower < range.upper && token.range.upper > range.lower {
            let clipped = ByteRange(max(range.lower, token.range.lower), min(range.upper, token.range.upper))
            if let ns = snapshot.text.nsRange(clipped) {
                value.addAttributes(
                    SyntaxPresentation.attributes(token: token, font: font, appearance: appearance),
                    range: NSRange(
                        location: ns.location - originUTF16,
                        length: ns.length
                    )
                )
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
    /// 返回：段落内合法 UTF-16 位置；系统未命中时按最近真实端点处理，不把系统哨兵用于正文偏移。
    func character(at point: NSPoint) -> Int {
        if let ascii {
            let result = ascii.character(at: point)
            synchronizeASCIIProjection()
            return result
        }
        for fragment in fragments {
            for line in fragment.textLineFragments {
                let box = line.typographicBounds.offsetBy(
                    dx: fragment.layoutFragmentFrame.minX,
                    dy: fragment.layoutFragmentFrame.minY
                )
                if point.y < box.maxY {
                    let local = NSPoint(x: point.x - box.minX, y: point.y - box.minY)
                    let index = line.characterIndex(for: local)
                    if index != NSNotFound, index >= 0, index <= content.rendered.length {
                        return index
                    }
                    // 行外命中可返回 NSNotFound，先选择原生字形端点，避免哨兵加上段落起点造成溢出。
                    let start = min(content.rendered.length, max(0, line.characterRange.location))
                    let count = min(content.rendered.length - start, max(0, line.characterRange.length))
                    let end = start + count
                    let first = line.locationForCharacter(at: start)
                    let last = line.locationForCharacter(at: end)
                    return abs(local.x - first.x) <= abs(local.x - last.x) ? start : end
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
        if let ascii {
            let result = ascii.caret(at: local)
            synchronizeASCIIProjection()
            return result
        }
        for fragment in fragments {
            for line in fragment.textLineFragments {
                let range = line.characterRange
                if local >= range.location && local <= range.location + range.length {
                    let p = line.locationForCharacter(at: local)
                    return NSRect(
                        x: p.x + line.typographicBounds.minX + fragment.layoutFragmentFrame.minX,
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
        guard unavailableReason == nil else {
            return []
        }
        if let ascii {
            return ascii.selectionRects(range)
        }
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

    /// 业务作用：滚动保留完整行坐标，只替换已有原生等宽证据的视口片段。
    /// 参数说明:
    /// - viewport: 当前实际可见正文区域。
    /// 返回：普通段落保持原布局，长 ASCII 行同步有界投影。
    func updateViewport(_ viewport: NSRect) {
        ascii?.updateViewport(viewport)
        synchronizeASCIIProjection()
    }

    /// 业务作用：文本服务投影与当前实际原生片段保持一致，不借旧窗口表示新视口。
    /// 参数说明: 无。
    /// 返回：窗口改变时重建只读内容适配，完整正文、行范围和字节位置不变。
    private func synchronizeASCIIProjection() {
        guard let ascii, content.projection != ascii.renderedRange else {
            return
        }
        content = ascii.content
        manager = ascii.manager
    }

    /// 业务作用：所有字形仍由 TextKit 2 绘制，安全长行只平移当前原生单行片段。
    /// 参数说明:
    /// - origin: 完整逻辑行在编辑视图中的起点。
    /// - context: 当前实际绘制上下文。
    /// 返回：完整原生段落或有界原生窗口完成呈现，不修改内核文本。
    func draw(at origin: NSPoint, in context: CGContext) {
        if let unavailableReason {
            NSAttributedString(
                string: unavailableReason,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemOrange,
                ]
            ).draw(at: origin)
            return
        }
        if let ascii {
            ascii.draw(at: origin, in: context)
            return
        }
        for fragment in fragments {
            context.saveGState()
            fragment.draw(
                at: NSPoint(
                    x: origin.x + fragment.layoutFragmentFrame.minX,
                    y: origin.y + fragment.layoutFragmentFrame.minY
                ),
                in: context
            )
            context.restoreGState()
        }
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
