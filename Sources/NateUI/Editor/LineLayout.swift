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
    private let horizontallyOrderedASCII: Bool
    private(set) var unavailableReason: String?
    private var nativeLines: [NativeLineGeometry] = []
    private var orderedPositions = true
    private var orderedHeights = true
    private let virtualFont: NSFont
    private let appearance: NSAppearance
    private var foregroundVariant: LineForegroundVariant?
    var syntaxBackgrounds: [(range: ByteRange, color: NSColor, fillsLineEnd: Bool)] = []

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
    /// - fontZoomAdjustment: 来源视图的实际点数差值，资源字号与继承字号分别采用同一缩放意图。
    /// - virtualSpaceFont: 空的文件末行没有词法字节时使用的来源默认样式字体。
    /// - width: 排版宽度。
    /// - tokens: 当前快照语法呈现。
    /// - rtl: 段落基础方向。
    /// - appearance: 所属视图的实际外观，布局可能发生在绘制回调之外。
    /// - viewport: 不换行时的真实可见正文矩形，省略时保留完整原生段落流程。
    /// - nativeASCII: 已证明独立 ASCII 的有界内部段落，关闭上下文连字与字距调整。
    /// - tabWidth: 当前语言的合法 Tab 停靠间距。
    /// - showSequences: 是否显示 ANSI 控制范围的原始占位与参数文字。
    /// - theme: 当前来源视图的完整固定主题。
    /// - language: 来源语言身份，用于隔离逐语言样式。
    /// 返回：只读 TextKit 2 布局缓存，控制字符只在呈现副本中使用等长占位，原文与坐标保持一致。
    init(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        fontZoomAdjustment: CGFloat = 0,
        virtualSpaceFont: NSFont? = nil,
        width: CGFloat,
        tokens: [SyntaxToken],
        rtl: Bool,
        appearance: NSAppearance,
        viewport: NSRect? = nil,
        nativeASCII: Bool = false,
        tabWidth: Int = 4,
        showSequences: Bool = false,
        theme: EditorThemeDefinition? = nil,
        language: String? = nil
    ) {
        self.range = range
        self.appearance = appearance
        let baseFont = EditorThemePresentation.baseFont(
            font,
            theme: theme,
            language: language,
            adjustment: fontZoomAdjustment
        )
        let ending = range.isEmpty ? range.lower : range.upper - 1
        if let token = tokens.first(where: {
            $0.range.lower <= ending && $0.range.upper > ending
        }) {
            virtualFont =
                SyntaxPresentation.attributes(
                    token: token,
                    font: font,
                    appearance: appearance,
                    fontZoomAdjustment: fontZoomAdjustment,
                    theme: theme,
                    language: language
                )[.font] as? NSFont ?? baseFont
        }
        else {
            virtualFont = virtualSpaceFont ?? baseFont
        }
        horizontallyOrderedASCII = !rtl && snapshot.text.isPrintableASCII(in: range)
        let origin = snapshot.text.utf16Offset(byte: range.lower) ?? 0
        originUTF16 = origin
        if !nativeASCII, !rtl, tokens.isEmpty, viewport != nil {
            ascii = ASCIILineWindow(
                snapshot: snapshot,
                range: range,
                font: font,
                appearance: appearance,
                theme: theme,
                language: language,
                fontZoomAdjustment: fontZoomAdjustment
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
            max(1, NSAttributedString(string: " ", attributes: [.font: baseFont]).size().width)
            * CGFloat(tabWidth)
        paragraph.tabStops = []
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: EditorThemePresentation.color(
                .foreground,
                fallback: .textColor,
                theme: theme,
                appearance: appearance,
                language: language
            ),
            .paragraphStyle: paragraph,
        ]
        if let theme {
            let defaults = SyntaxThemeSelection.defaults(theme: theme, language: language)
            attributes[.underlineStyle] =
                (defaults.fontStyle ?? 0) & 4 != 0 ? NSUnderlineStyle.single.rawValue : 0
        }
        if nativeASCII {
            attributes[.ligature] = 0
            attributes[.kern] = 0
        }
        let hidden: [NSRange] =
            showSequences
            ? []
            : tokens.compactMap {
                token in
                guard ["ansi:171", "ansi:172", "error:23", "error:24"].contains(token.lexicalStyle),
                    token.range.lower < range.upper, token.range.upper > range.lower,
                    let native = snapshot.text.nsRange(
                        ByteRange(max(range.lower, token.range.lower), min(range.upper, token.range.upper))
                    )
                else {
                    return nil
                }
                return NSRange(location: native.location - origin, length: native.length)
            }
        let value = NSMutableAttributedString(
            string: LineControlPresentation.hidingSequences(
                LineControlPresentation.render(snapshot.text.text(in: range)),
                ranges: hidden
            ),
            attributes: attributes
        )
        for token in tokens where token.range.lower < range.upper && token.range.upper > range.lower {
            let clipped = ByteRange(max(range.lower, token.range.lower), min(range.upper, token.range.upper))
            if let ns = snapshot.text.nsRange(clipped) {
                var attributes = SyntaxPresentation.attributes(
                    token: token,
                    font: font,
                    appearance: appearance,
                    fontZoomAdjustment: fontZoomAdjustment,
                    theme: theme,
                    language: language
                )
                if let color = attributes.removeValue(forKey: .backgroundColor) as? NSColor {
                    syntaxBackgrounds.append(
                        (
                            range: clipped,
                            color: color,
                            fillsLineEnd: token.lexicalStyle == "props:2"
                        )
                    )
                }
                // 背景使用同一原生字形矩形先行绘制，不能让段落背景覆盖相邻行或稍后绘制的选择。
                value.addAttributes(
                    attributes,
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
                self.indexLines(in: fragment)
                self.height = max(self.height, fragment.layoutFragmentFrame.maxY)
                self.width = max(self.width, fragment.layoutFragmentFrame.maxX)
                return false
            }
        }
    }

    /// 业务作用：行末虚拟空间采用最后正文字形的字体，空行采用其结束符或文件末默认样式。
    /// 参数说明: 无。
    /// 返回：当前行至少一个像素的原生空格宽度，不从基础编辑器字体猜测资源字号。
    var virtualColumnWidth: Double {
        max(1, Double((" " as NSString).size(withAttributes: [.font: virtualFont]).width))
    }

    /// 业务作用：部分 Tab 的空格列数采用该 Tab 的实际字体，不能以另一行或基础字号展开其像素范围。
    /// 参数说明:
    /// - local: 当前完整逻辑行内的 UTF-16 位置。
    /// 返回：该位置原生字体的空格宽度；安全 ASCII 窗口及行尾采用已固定的行末字体。
    func columnWidth(at local: Int) -> Double {
        let actual: NSFont
        if ascii == nil, local >= 0, local < content.rendered.length,
            let font = content.rendered.attribute(.font, at: local, effectiveRange: nil) as? NSFont
        {
            actual = font
        }
        else {
            actual = virtualFont
        }
        return max(1, Double((" " as NSString).size(withAttributes: [.font: actual]).width))
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
        return visualLine(at: point.y)?.character(at: point) ?? content.rendered.length
    }

    /// 业务作用：通过 TextKit 选区片段查询光标与候选框位置。
    /// 参数说明:
    /// - local: 段落内 UTF-16 位置。
    /// - downstream: 字符标记取软换行后的实际所属行，光标默认保留上游亲和性。
    /// 返回：段落内光标矩形。
    func caret(at local: Int, downstream: Bool = false) -> NSRect {
        if let ascii {
            let result = ascii.caret(at: local)
            synchronizeASCIIProjection()
            return result
        }
        let result =
            visualLine(containing: local, downstream: downstream)?.caret(at: local)
            ?? NSRect(x: 0, y: 0, width: 1.5, height: height)
        // 尾随空格的真实插入点可能超过原生容器，保留已证明的边缘以免重绘收回可见光标。
        width = max(width, result.maxX)
        return result
    }

    /// 业务作用：原生视觉行一次建立索引，只有实际范围与高度均有序时才允许二分查询。
    /// 参数说明:
    /// - fragment: 已完成排版的当前逻辑段落片段。
    /// 返回：保留原生顺序及坐标；异常范围整体暂停呈现，不发布部分索引。
    private func indexLines(in fragment: NSTextLayoutFragment) {
        for line in fragment.textLineFragments {
            guard
                let item = NativeLineGeometry(
                    line: line,
                    origin: fragment.layoutFragmentFrame.origin,
                    sourceLength: content.rendered.length
                )
            else {
                unavailableReason = "原生视觉行缺少完整范围或像素证据，当前呈现已暂停；原正文保持不变。"
                nativeLines.removeAll()
                return
            }
            if let prior = nativeLines.last {
                orderedPositions = orderedPositions && prior.lower <= item.lower && prior.upper <= item.upper
                orderedHeights = orderedHeights && prior.bounds.maxY <= item.bounds.maxY
            }
            nativeLines.append(item)
        }
    }

    /// 业务作用：按真实 UTF-16 位置取得首个包含端点的视觉行，软换行边界保持原有上游位置。
    /// 参数说明:
    /// - local: 当前段落内的真实 UTF-16 位置。
    /// - downstream: 是否选择字符实际所属的后续视觉行。
    /// 返回：原生行证据或空；原生顺序不具备二分条件时按既有顺序查询。
    private func visualLine(containing local: Int, downstream: Bool) -> NativeLineGeometry? {
        guard orderedPositions else {
            return nativeLines.first {
                local >= $0.lower && (downstream ? local < $0.upper : local <= $0.upper)
            }
        }
        var lower = 0, upper = nativeLines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if downstream ? nativeLines[middle].upper <= local : nativeLines[middle].upper < local {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard nativeLines.indices.contains(lower), local >= nativeLines[lower].lower else {
            return nil
        }
        return nativeLines[lower]
    }

    /// 业务作用：按原生视觉行的真实下边缘定位命中行，不逐次扫描长段落的全部软换行。
    /// 参数说明:
    /// - y: 相对当前逻辑段落的纵坐标。
    /// 返回：首个实际覆盖该高度的原生行，段落尾部之外为空。
    private func visualLine(at y: CGFloat) -> NativeLineGeometry? {
        guard orderedHeights else {
            return nativeLines.first {
                y < $0.bounds.maxY
            }
        }
        var lower = 0, upper = nativeLines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if y < nativeLines[middle].bounds.maxY {
                upper = middle
            }
            else {
                lower = middle + 1
            }
        }
        return nativeLines.indices.contains(lower) ? nativeLines[lower] : nil
    }

    /// 业务作用：空白标记只读取当前视口覆盖的真实视觉行，不因一个逻辑行很长就展开全部正文。
    /// 参数说明:
    /// - viewport: 相对逻辑段落起点的实际视口。
    /// 返回：完整 UTF-8 可见范围列表，不改变逻辑行或原选择。
    func visibleByteRanges(in viewport: NSRect) -> [ByteRange] {
        guard unavailableReason == nil else {
            return []
        }
        if let ascii {
            return ascii.visibleByteRanges(in: viewport)
        }
        var ranges: [ByteRange] = []
        for row in nativeLines where row.bounds.maxY > viewport.minY && row.bounds.minY < viewport.maxY {
            let visible =
                horizontallyOrderedASCII
                ? row.visibleASCIICharacters(in: viewport)
                : NSRange(location: row.lower, length: row.upper - row.lower)
            if let range = content.snapshot.text.byteRange(
                NSRange(location: originUTF16 + visible.location, length: visible.length)
            ), !range.isEmpty {
                ranges.append(range)
            }
        }
        return ranges
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

    /// 业务作用：明确选择前景沿原行字体和容器绘制，长 ASCII 行仍只处理原生窗口。
    /// 参数说明:
    /// - origin: 原行实际绘制原点。
    /// - color: 来源主题的明确选择前景。
    /// - context: 调用方已按原选择字形裁剪的上下文。
    /// 返回：仅改变选中区域文字颜色，不修改原布局、正文或历史。
    func drawForeground(at origin: NSPoint, color: NSColor, in context: CGContext) {
        guard unavailableReason == nil else {
            return
        }
        if let ascii {
            ascii.drawForeground(at: origin, color: color, in: context)
            return
        }
        if foregroundVariant?.color != color {
            foregroundVariant = LineForegroundVariant(
                source: content,
                color: color,
                width: manager.textContainer?.size.width ?? width,
                appearance: appearance
            )
        }
        foregroundVariant?.draw(at: origin, in: context)
    }
}
