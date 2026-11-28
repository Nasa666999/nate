import AppKit
import NateCore

@MainActor
final class LongLineWindow: LongLineProjection {
    let snapshot: DocumentSnapshot
    let range: ByteRange
    let advance: CGFloat
    let font: NSFont
    let appearance: NSAppearance
    let theme: EditorThemeDefinition?
    let language: String?
    let fontZoomAdjustment: CGFloat
    let characterCount: Int
    private let tabs: ASCIITabColumns?
    private let han: NativeHanProjection?
    private let narrow: PlainNarrowUnicodeLine?
    private let combining: PlainCombiningLine?
    private(set) var unavailableReason: String?
    private(set) var renderedRange: ByteRange
    private var renderedCharacters: Range<Int>
    private var offsetX: CGFloat = 0
    private var native: LineLayout

    var rendered: NSAttributedString {
        native.content.rendered
    }
    var content: EditorContentManager {
        native.content
    }
    var manager: NSTextLayoutManager {
        native.manager
    }
    var height: CGFloat {
        native.height
    }
    var width: CGFloat {
        han?.width ?? distance(through: characterCount)
    }

    /// 业务作用：完整原文字符集与各自实际原生步距均得到证明时，才用有界原生段落替代整条长行。
    /// 参数说明:
    /// - snapshot: 唯一正文的固定快照。
    /// - range: 完整逻辑行原字节范围。
    /// - font: 当前视图真实字体。
    /// - appearance: 当前视图实际外观。
    /// - theme: 来源视图固定主题。
    /// - language: 当前来源语言身份。
    /// - fontZoomAdjustment: 原字体的实际缩放差值，主题字号只叠加一次。
    /// - tabWidth: 当前来源视图的实际 Tab 停靠宽度。
    /// - tabs: 本行原文已经准备好的真实 Tab 列索引；纯可打印 ASCII 可省略。
    /// - hanLine: 完整原文为基本汉字与可打印 ASCII 时使用的不可变行索引。
    /// - hanTabLine: 含真实 Tab 且已绑定原文、字体及制表网格的证据。
    /// - narrowLine: 当前原文中使用同一基础字体的独立 Unicode 字母证据。
    /// - combiningLine: 同一原文中经实际基础字体复验的拉丁组合字形坐标。
    /// 返回：符合安全条件时保留有界原生窗口，否则不授予安全坐标资格。
    init?(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        appearance: NSAppearance,
        theme: EditorThemeDefinition? = nil,
        language: String? = nil,
        fontZoomAdjustment: CGFloat = 0,
        tabWidth: Int = 4,
        tabs: ASCIITabColumns? = nil,
        hanLine: PlainHanLine? = nil,
        hanTabLine: HanTabColumns? = nil,
        narrowLine: PlainNarrowUnicodeLine? = nil,
        combiningLine: PlainCombiningLine? = nil
    ) {
        let actualFont = EditorThemePresentation.baseFont(
            font,
            theme: theme,
            language: language,
            adjustment: fontZoomAdjustment
        )
        // 整行字节与原生步距必须同时得到证明，缺少任一证据都不能为远处前缀计算字形坐标。
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= snapshot.text.byteCount,
            range.count >= EditorNativeLayoutPolicy.asciiMinimumBytes,
            range.count <= EditorNativeLayoutPolicy.maximumDocumentBytes,
            tabs == nil || (tabs?.range == range && tabs?.tabWidth == tabWidth),
            hanLine == nil
                || (tabs == nil && hanLine?.range == range && hanLine?.matches(snapshot.text) == true),
            hanTabLine == nil
                || (tabs == nil && hanLine == nil && hanTabLine?.range == range
                    && hanTabLine?.matches(snapshot.text, tabWidth: tabWidth) == true),
            narrowLine == nil
                || (tabs == nil && hanLine == nil && hanTabLine == nil
                    && narrowLine?.range == range && narrowLine?.matches(snapshot.text) == true),
            combiningLine == nil
                || (tabs == nil && hanLine == nil && hanTabLine == nil && narrowLine == nil
                    && combiningLine?.range == range
                    && combiningLine?.matches(snapshot.text, tabWidth: tabWidth) == true),
            tabs != nil || hanLine != nil || hanTabLine != nil || narrowLine != nil || combiningLine != nil
                || snapshot.text.isPrintableASCII(in: range),
            let advance = NativeMonospaceGeometry.uniformAdvance(actualFont, appearance: appearance)
        else {
            return nil
        }
        // 只有实际字体的原生 Tab 停靠与列索引完全一致时，才允许平移远处段落。
        if let tabs,
            !NativeMonospaceGeometry.provesTabStops(
                actualFont,
                width: tabs.tabWidth,
                advance: advance,
                appearance: appearance
            )
        {
            return nil
        }
        if let narrowLine,
            !NativeNarrowUnicodeFont.proves(
                narrowLine.scalars,
                font: actualFont,
                advance: advance,
                appearance: appearance
            )
        {
            return nil
        }
        if let combiningLine {
            // 组合字体度量只对当前原样本成立，字体替换后必须复验实际插入点才能采用远端坐标。
            guard
                NativeNarrowUnicodeFont.provesCombining(
                    combiningLine.combiningPairs,
                    font: actualFont,
                    advance: advance,
                    appearance: appearance,
                    tabWidth: combiningLine.tabWidth
                ),
                combiningLine.independentScalars.isEmpty
                    || NativeNarrowUnicodeFont.proves(
                        combiningLine.independentScalars,
                        font: actualFont,
                        advance: advance,
                        appearance: appearance
                    )
            else {
                return nil
            }
        }
        let han: NativeHanProjection?
        if hanLine != nil || hanTabLine != nil {
            guard
                let measured = NativeHanProjection(
                    plain: hanLine,
                    tabbed: hanTabLine,
                    base: actualFont,
                    ascii: advance,
                    appearance: appearance
                )
            else {
                return nil
            }
            han = measured
        }
        else {
            han = nil
        }
        self.snapshot = snapshot
        self.range = range
        self.font = font
        self.appearance = appearance
        self.theme = theme
        self.language = language
        self.fontZoomAdjustment = fontZoomAdjustment
        self.advance = advance
        self.tabs = tabs
        self.han = han
        narrow = narrowLine
        combining = combiningLine
        let count =
            han?.characterCount ?? narrowLine?.characterCount ?? combiningLine?.characterCount ?? range.count
        characterCount = count
        let candidateEnd = min(count, 8192)
        let upper = combiningLine?.boundary(atOrBefore: candidateEnd) ?? candidateEnd
        let initialByte: Int
        let initialWidth: CGFloat
        if let han {
            guard let byte = han.byte(at: upper), let point = han.geometry(at: upper)
            else {
                return nil
            }
            initialByte = byte
            initialWidth = point.distance
        }
        else if let narrowLine {
            guard let byte = narrowLine.byte(at: upper) else {
                return nil
            }
            initialByte = byte
            initialWidth = CGFloat(upper) * advance
        }
        else if let combiningLine {
            guard let byte = combiningLine.byte(at: upper), let cell = combiningLine.cell(at: upper) else {
                return nil
            }
            initialByte = byte
            initialWidth = CGFloat(cell) * advance
        }
        else {
            initialByte = range.lower + upper
            initialWidth = CGFloat(tabs?.column(at: upper) ?? upper) * advance
        }
        renderedCharacters = 0..<upper
        renderedRange = ByteRange(range.lower, initialByte)
        native = Self.project(
            snapshot: snapshot,
            range: renderedRange,
            font: font,
            appearance: appearance,
            width: initialWidth,
            theme: theme,
            language: language,
            fontZoomAdjustment: fontZoomAdjustment,
            tabWidth: tabs?.tabWidth ?? han?.tabWidth ?? combiningLine?.tabWidth ?? 4,
            hanFont: han?.font
        )
        // 只有真实原生段落与已确认字体度量一致，才允许沿正文前缀平移后续窗口。
        if han != nil || narrow != nil || combining != nil {
            let start = native.caret(at: 0)
            let end = native.caret(at: upper)
            guard native.isSingleVisualLine, native.characterCount == upper,
                abs(end.minX - start.minX - initialWidth) < 0.02,
                abs(end.minY - start.minY) < 0.01
            else {
                return nil
            }
        }
    }

    /// 业务作用：滚动只替换视口附近的原生片段，字节坐标与完整行宽保持原样。
    /// 参数说明:
    /// - viewport: 相对正文行起点的实际可见矩形。
    /// 返回：窗口覆盖真实可见范围，最多保留 65536 个已验证的 UTF-16 单元。
    func updateViewport(_ viewport: NSRect) {
        let x = viewport.minX.isFinite ? max(0, viewport.minX) : 0
        let visibleWidth = viewport.width.isFinite ? max(1, viewport.width) : 900
        let first = offset(at: x)
        let last = offset(at: min(width, x + min(width, visibleWidth)))
        if first >= renderedCharacters.lowerBound,
            last <= renderedCharacters.upperBound
        {
            unavailableReason = nil
            return
        }
        project(around: first, visibleColumns: max(1, last - first))
    }

    /// 业务作用：有界索引只用于取窗口，实际字形的像素命中由原生段落确定。
    /// 参数说明:
    /// - point: 相对完整逻辑行起点的命中位置。
    /// 返回：完整行内的 UTF-16 偏移，系统哨兵由原生段落适配收束。
    func character(at point: NSPoint) -> Int {
        let x = point.x.isFinite ? min(width, max(0, point.x)) : 0
        let approximate = offset(at: x)
        if han != nil || narrow != nil || combining != nil {
            return nearestInsertion(to: x, around: approximate)
        }
        guard ensureColumn(approximate) else {
            return 0
        }
        let index = native.character(
            at: NSPoint(
                x: x - offsetX,
                y: point.y.isFinite ? point.y : 0
            )
        )
        return renderedCharacters.lowerBound + index
    }

    /// 业务作用：Unicode 字形命中使用相邻的真实插入点，组合字形只作为完整单位参与选择。
    /// 参数说明:
    /// - x: 长行完整坐标中的实际命中位置。
    /// - approximate: 由已验证前缀步距定位的相邻字符。
    /// 返回：最接近位置的原生插入点；等距时选前一个真实端点。
    private func nearestInsertion(to x: CGFloat, around approximate: Int) -> Int {
        let following: Int
        if let combining {
            following = combining.boundary(atOrAfter: min(characterCount, approximate + 1)) ?? approximate
        }
        else {
            following = min(characterCount, approximate + 1)
        }
        guard ensureColumn(approximate), ensureColumn(following) else {
            return 0
        }
        let first = combining == nil ? max(renderedCharacters.lowerBound, approximate - 1) : approximate
        let candidates = combining == nil ? Array(first...following) : [first, following]
        let base = renderedCharacters.lowerBound
        var nearest = first
        var distance = CGFloat.infinity
        for character in candidates {
            let caret = native.caret(at: character - base)
            let difference = abs(caret.minX + offsetX - x)
            if difference < distance {
                nearest = character
                distance = difference
            }
        }
        return nearest
    }

    /// 业务作用：远处光标先投影附近原文，再从已经排版的字形取得插入位置。
    /// 参数说明:
    /// - local: 相对完整逻辑行的 UTF-16 偏移。
    /// - downstream: 调用点的软换行亲和性，单个视觉行的两种亲和性使用同一位置。
    /// 返回：同一完整行坐标中的原生光标矩形，不建立前缀字形副本。
    func caret(at local: Int, downstream: Bool) -> NSRect {
        let column = min(characterCount, max(0, local))
        guard ensureColumn(column) else {
            return .zero
        }
        return native.caret(at: column - renderedCharacters.lowerBound).offsetBy(dx: offsetX, dy: 0)
    }

    /// 业务作用：完整选择仅为实际原生窗口内的交集生成背景，内核范围不被截断。
    /// 参数说明:
    /// - selection: 原快照中的完整选择。
    /// 返回：原生可见矩形，窗口之外不生成无用片段。
    func selectionRects(_ selection: ByteRange) -> [NSRect] {
        let lower = max(selection.lower, renderedRange.lower)
        let upper = min(selection.upper, renderedRange.upper)
        guard lower < upper else {
            return []
        }
        return native.selectionRects(ByteRange(lower, upper)).map {
            $0.offsetBy(dx: offsetX, dy: 0)
        }
    }

    /// 业务作用：空白标记只访问实际视口附近的已验证原文，避免在整个窗口逐字符绘制不可见标记。
    /// 参数说明:
    /// - viewport: 相对完整逻辑行的可见矩形。
    /// 返回：当前窗口内覆盖视口的完整原字节范围，行外与非法矩形为空。
    func visibleByteRanges(in viewport: NSRect) -> [ByteRange] {
        guard viewport.minX.isFinite, viewport.maxX.isFinite,
            viewport.maxY > 0, viewport.minY < height
        else {
            return []
        }
        let first = max(0, offset(at: viewport.minX) - 1)
        let last = min(characterCount, offset(at: viewport.maxX) + 2)
        guard let begin = byte(at: combining?.boundary(atOrBefore: first) ?? first),
            let end = byte(at: combining?.boundary(atOrAfter: last) ?? last)
        else {
            return []
        }
        let lower = max(renderedRange.lower, begin)
        let upper = min(renderedRange.upper, end)
        return lower < upper ? [ByteRange(lower, upper)] : []
    }

    /// 业务作用：由 TextKit 2 完成原生字形绘制，只平移已确认原生步距的完整前缀距离。
    /// 参数说明:
    /// - origin: 完整逻辑行在编辑视图中的起点。
    /// - context: 当前实际绘制上下文。
    /// 返回：绘制有界原生片段，不更改正文或其它视图布局。
    func draw(at origin: NSPoint, in context: CGContext) {
        native.draw(
            at: NSPoint(
                x: origin.x + offsetX,
                y: origin.y
            ),
            in: context
        )
    }

    /// 业务作用：长行选择前景只重绘当前有限原生窗口，未请求的完整行不展开。
    /// 参数说明:
    /// - origin: 完整行的来源绘制原点。
    /// - color: 当前来源主题的明确选择前景。
    /// - context: 已按真实选择范围裁剪的上下文。
    /// 返回：窗口字形沿同一横向投影绘制，其它行和原坐标保持。
    func drawForeground(at origin: NSPoint, color: NSColor, in context: CGContext) {
        native.drawForeground(
            at: NSPoint(x: origin.x + offsetX, y: origin.y),
            color: color,
            in: context
        )
    }

    /// 业务作用：同一视口中的多个光标与背景共用当前段落，不逐项反复排版。
    /// 参数说明:
    /// - column: 已收束到完整行内的真实字符偏移。
    /// 返回：当前原生段落已经确认包含目标端点时为真。
    private func ensureColumn(_ column: Int) -> Bool {
        if column >= renderedCharacters.lowerBound, column <= renderedCharacters.upperBound {
            unavailableReason = nil
            return true
        }
        project(around: column, visibleColumns: 1)
        return unavailableReason == nil
            && column >= renderedCharacters.lowerBound && column <= renderedCharacters.upperBound
    }

    /// 业务作用：投影只读取有界连续原文，分组保留滚动重用空间与真实 UTF-8 端点。
    /// 参数说明:
    /// - column: 当前真实视口或导航目标。
    /// - visibleColumns: 本次可见字符预算。
    /// 返回：重新排版最多 65536 个字符，完整逻辑行范围保持原状。
    private func project(around column: Int, visibleColumns: Int) {
        let count = min(
            characterCount,
            min(
                EditorNativeLayoutPolicy.maximumWindowCharacters,
                max(8192, min(57_344, visibleColumns) + 8192)
            )
        )
        var lower = min(max(0, characterCount - count), max(0, column / 4096 * 4096 - 1024))
        if let tabs {
            let startColumn = self.column(for: lower)
            // 窗口从真实停靠位起排，局部 Tab 才与完整逻辑行共享同一原生制表网格。
            lower = tabs.offset(atOrBefore: startColumn - startColumn % tabs.tabWidth) ?? 0
        }
        if let combining {
            // 窗口切边必须落在组合字形两侧，独立布局才不会将方才的附标当作另一字形。
            lower = combining.boundary(atOrBefore: lower) ?? lower
        }
        let upper = combining?.boundary(atOrBefore: lower + count) ?? lower + count
        guard let begin = byte(at: lower), let end = byte(at: upper) else {
            return
        }
        let next = ByteRange(begin, end)
        guard next != renderedRange else {
            unavailableReason = nil
            return
        }
        let beginning = han?.geometry(at: lower)
        let startX = beginning?.distance ?? distance(through: lower)
        // 裁剪片段沿完整行的制表格起排，即使其首字形位于两个停靠列之间。
        let combiningPhase = combining?.tabWidth.map { CGFloat(self.column(for: lower) % $0) * advance } ?? 0
        let phase = beginning?.phase ?? combiningPhase
        let endX = distance(through: upper)
        let windowWidth = endX - startX
        let candidate = Self.project(
            snapshot: snapshot,
            range: next,
            font: font,
            appearance: appearance,
            width: windowWidth,
            theme: theme,
            language: language,
            fontZoomAdjustment: fontZoomAdjustment,
            tabWidth: tabs?.tabWidth ?? han?.tabWidth ?? combining?.tabWidth ?? 4,
            hanFont: han?.font,
            tabPhase: phase
        )
        if han?.tabWidth != nil || narrow != nil || combining != nil {
            let start = candidate.caret(at: 0)
            let end = candidate.caret(at: upper - lower)
            // 每个混合窗口也必须复验真实段落几何，浮点或原生布局失配时立即撤回坐标权限。
            guard candidate.isSingleVisualLine, abs(start.minX - phase) < 0.02,
                abs(end.minX - start.minX - windowWidth) < 0.02,
                combining == nil
                    || (candidate.characterCount == upper - lower
                        && abs(candidate.height - native.height) < 0.02)
            else {
                unavailableReason =
                    narrow != nil || combining != nil
                    ? "超长 Unicode 行的实际字形间距无法确认，已暂停字形呈现。"
                    : "超长汉字行的原生 Tab 停靠位置无法确认，已暂停字形呈现。"
                return
            }
        }
        unavailableReason = nil
        renderedRange = next
        renderedCharacters = lower..<upper
        offsetX = startX - phase
        native = candidate
    }

    /// 业务作用：浮点系统位置先收束到已验证行容量，再转为整数，哨兵和无穷值不得进入正文位置。
    /// 参数说明:
    /// - x: 已经确认有限的正文横坐标。
    /// 返回：完整行内不越过横坐标的真实 UTF-16 端点。
    private func offset(at x: CGFloat) -> Int {
        if let han {
            return han.character(atOrBefore: min(width, max(0, x))) ?? 0
        }
        let count = tabs?.columnCount ?? combining?.cellCount ?? characterCount
        let column = Int(min(CGFloat(count), max(0, floor(x / advance))))
        return tabs?.offset(atOrBefore: column) ?? combining?.character(atCell: column) ?? column
    }

    /// 业务作用：从原生窗口端点取得完整行中的制表或实际字形列。
    /// 参数说明:
    /// - offset: 已限制在完整逻辑行内的相对 UTF-16 端点。
    /// 返回：有 Tab 或组合字形时按已验证索引映射，独立窄字形采用原偏移。
    private func column(for offset: Int) -> Int {
        tabs?.column(at: offset) ?? combining?.cell(at: offset) ?? offset
    }

    /// 业务作用：把长行内已验证字符端点映射到正文原始字节，有汉字时使用内核的严格转换。
    /// 参数说明:
    /// - character: 行首起算的 UTF-16 端点。
    /// 返回：原正文绝对字节位置，行外端点为空。
    private func byte(at character: Int) -> Int? {
        if let han {
            return han.byte(at: character)
        }
        if let narrow {
            return narrow.byte(at: character)
        }
        if let combining {
            return combining.byte(at: character)
        }
        return (0...characterCount).contains(character) ? range.lower + character : nil
    }

    /// 业务作用：每个原生窗口与导航共享同一完整前缀距离，远处窗口也能准确平移到本行坐标。
    /// 参数说明:
    /// - character: 已验证在本行内的 UTF-16 端点。
    /// 返回：相对逻辑行起点的横坐标。
    private func distance(through character: Int) -> CGFloat {
        if let han {
            return han.geometry(at: character)?.distance ?? 0
        }
        return CGFloat(column(for: character)) * advance
    }

    /// 业务作用：有界段落仍经过真实布局管理器，关闭上下文连字与字距调整以复用等宽证据。
    /// 参数说明:
    /// - snapshot: 当前固定正文。
    /// - range: 有界原文范围。
    /// - font: 实际原生字体。
    /// - appearance: 实际视图外观。
    /// - width: 本窗口实际占据的横向距离。
    /// - theme: 来源固定主题。
    /// - language: 来源语言身份。
    /// - fontZoomAdjustment: 主题字号的原视图缩放差值。
    /// - tabWidth: 当前语言的实际制表列数。
    /// - hanFont: 已经验证并应用于基本汉字的原生度量。
    /// - tabPhase: 裁剪后原生第一行相对同一实际制表网格的偏量。
    /// 返回：已完成 TextKit 2 排版的只读片段，不强制排版未请求正文。
    static func project(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        appearance: NSAppearance,
        width: CGFloat,
        theme: EditorThemeDefinition?,
        language: String?,
        fontZoomAdjustment: CGFloat,
        tabWidth: Int,
        hanFont: NativeHanLineFont? = nil,
        tabPhase: CGFloat = 0
    ) -> LineLayout {
        return LineLayout(
            snapshot: snapshot,
            range: range,
            font: font,
            fontZoomAdjustment: fontZoomAdjustment,
            width: width + 64,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true,
            nativeHanFont: hanFont,
            tabWidth: tabWidth,
            nativeTabPhase: tabPhase,
            theme: theme,
            language: language
        )
    }
}
