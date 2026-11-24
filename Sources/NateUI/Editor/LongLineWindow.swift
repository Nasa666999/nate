import AppKit
import NateCore

@MainActor
final class LongLineWindow: LongLineProjection {
    private struct TabProof: Hashable {
        let font: NSFont
        let width: Int
    }

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
    private(set) var unavailableReason: String?
    private(set) var renderedRange: ByteRange
    private var renderedCharacters: Range<Int>
    private var offsetX: CGFloat = 0
    private var native: LineLayout
    private static var advances: [NSFont: CGFloat] = [:]
    private static var rejected: Set<NSFont> = []
    private static var tabProofs: [TabProof: Bool] = [:]

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
        hanTabLine: HanTabColumns? = nil
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
            tabs != nil || hanLine != nil || hanTabLine != nil || snapshot.text.isPrintableASCII(in: range),
            let advance = Self.uniformAdvance(actualFont, appearance: appearance)
        else {
            return nil
        }
        // 只有实际字体的原生 Tab 停靠与列索引完全一致时，才允许平移远处段落。
        if let tabs,
            !Self.provesTabStops(actualFont, width: tabs.tabWidth, advance: advance, appearance: appearance)
        {
            return nil
        }
        let han: NativeHanProjection?
        if hanLine != nil || hanTabLine != nil {
            guard
                let measured = NativeHanProjection(
                    plain: hanLine,
                    tabbed: hanTabLine,
                    base: actualFont,
                    ascii: advance
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
        let count = han?.characterCount ?? range.count
        characterCount = count
        let upper = min(count, 8192)
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
            tabWidth: tabs?.tabWidth ?? han?.tabWidth ?? 4,
            hanFont: han?.font
        )
        // 只有真实原生段落与已确认字体度量一致，才允许沿正文前缀平移后续窗口。
        if han != nil {
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

    /// 业务作用：有界索引只用于取窗口，可打印 ASCII、真实 Tab 与基本汉字的像素命中仍由原生段落确定。
    /// 参数说明:
    /// - point: 相对完整逻辑行起点的命中位置。
    /// 返回：完整行内的 UTF-16 偏移，系统哨兵由原生段落适配收束。
    func character(at point: NSPoint) -> Int {
        let x = point.x.isFinite ? min(width, max(0, point.x)) : 0
        let approximate = offset(at: x)
        if han != nil {
            return nearestHanInsertion(to: x, around: approximate)
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

    /// 业务作用：独立汉字或 ASCII 的命中采用邻近真实插入点，避免百万像素平移下浮点消减跨到前一标量。
    /// 参数说明:
    /// - x: 长行完整坐标中的实际命中位置。
    /// - approximate: 由已验证前缀步距定位的相邻字符。
    /// 返回：最接近位置的原生插入点；等距时选前一个真实端点。
    private func nearestHanInsertion(to x: CGFloat, around approximate: Int) -> Int {
        guard ensureColumn(approximate), ensureColumn(min(characterCount, approximate + 1)) else {
            return 0
        }
        let first = max(renderedCharacters.lowerBound, approximate - 1)
        let last = min(renderedCharacters.upperBound, approximate + 1)
        let base = renderedCharacters.lowerBound
        var nearest = first
        var distance = CGFloat.infinity
        for character in first...last {
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
        guard let begin = byte(at: max(0, offset(at: viewport.minX) - 1)),
            let end = byte(at: min(characterCount, offset(at: viewport.maxX) + 2))
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
        let upper = lower + count
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
        let phase = beginning?.phase ?? 0
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
            tabWidth: tabs?.tabWidth ?? han?.tabWidth ?? 4,
            hanFont: han?.font,
            tabPhase: phase
        )
        if han?.tabWidth != nil {
            let start = candidate.caret(at: 0)
            let end = candidate.caret(at: count)
            // 每个混合窗口也必须复验真实段落几何，浮点或原生布局失配时立即撤回坐标权限。
            guard candidate.isSingleVisualLine, abs(start.minX - phase) < 0.02,
                abs(end.minX - start.minX - windowWidth) < 0.02
            else {
                unavailableReason = "超长汉字行的原生 Tab 停靠位置无法确认，已暂停字形呈现。"
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
        let count = tabs?.columnCount ?? characterCount
        let column = Int(min(CGFloat(count), max(0, floor(x / advance))))
        return tabs?.offset(atOrBefore: column) ?? column
    }

    /// 业务作用：从原生窗口的原字节端点取得完整行中的实际制表列。
    /// 参数说明:
    /// - offset: 已限制在完整逻辑行内的字节端点。
    /// 返回：有 Tab 时按已验证索引映射，纯 ASCII 直接采用原偏移。
    private func column(for offset: Int) -> Int {
        tabs?.column(at: offset) ?? offset
    }

    /// 业务作用：把长行内已验证字符端点映射到正文原始字节，有汉字时使用内核的严格转换。
    /// 参数说明:
    /// - character: 行首起算的 UTF-16 端点。
    /// 返回：原正文绝对字节位置，行外端点为空。
    private func byte(at character: Int) -> Int? {
        if let han {
            return han.byte(at: character)
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
    private static func project(
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

    /// 业务作用：用真实原生段落复验每种起始余数，固定字体声明不足以单独证明制表坐标。
    /// 参数说明:
    /// - font: 完整窗口使用的实际字体。
    /// - width: 当前语言的实际 Tab 宽度。
    /// - advance: 已验证的单列原生步距。
    /// - appearance: 该视图实际采用的系统外观。
    /// 返回：所有原文端点均与真实原生制表位一致时为真；其余情况不使用长行快速布局。
    private static func provesTabStops(
        _ font: NSFont,
        width: Int,
        advance: CGFloat,
        appearance: NSAppearance
    ) -> Bool {
        let key = TabProof(font: font, width: width)
        if let valid = tabProofs[key] {
            return valid
        }
        let text = PieceTree((0..<width).map { String(repeating: "x", count: $0) + "\t" }.joined() + "x")
        let range = ByteRange(0, text.byteCount)
        guard let columns = try? ASCIITabColumns(text: text, range: range, tabWidth: width) else {
            return false
        }
        let sample = Self.project(
            snapshot: DocumentSnapshot(id: UUID(), revision: 0, text: text),
            range: range,
            font: font,
            appearance: appearance,
            width: CGFloat(columns.columnCount) * advance,
            theme: nil,
            language: nil,
            fontZoomAdjustment: 0,
            tabWidth: width
        )
        let origin = sample.caret(at: 0)
        let valid = (0...text.byteCount).allSatisfy { offset in
            let caret = sample.caret(at: offset)
            guard let column = columns.column(at: offset) else {
                return false
            }
            return abs(caret.minX - origin.minX - CGFloat(column) * advance) < 0.01
                && abs(caret.minY - origin.minY) < 0.01
        }
        if tabProofs.count >= 32 {
            tabProofs.removeAll()
        }
        tabProofs[key] = valid
        return valid
    }

    /// 业务作用：字体声明与全部已排版 ASCII 位置共同决定等宽资格，未排版片段不能提供步距证据。
    /// 参数说明:
    /// - font: 当前真实字体。
    /// - appearance: 当前真实视图外观。
    /// 返回：全部字符位置一致时提供真实步距，否则拒绝；证据缓存各最多三十二项。
    static func uniformAdvance(_ font: NSFont, appearance: NSAppearance) -> CGFloat? {
        if let value = advances[font] {
            return value
        }
        guard font.isFixedPitch, !rejected.contains(font) else {
            return nil
        }
        let text = PieceTree(String(decoding: Array(UInt8(32)...UInt8(126)), as: UTF8.self))
        // 未经布局管理器处理的片段没有有效坐标，先完成这个有界段落再读取真实字符位置。
        let sample = LineLayout(
            snapshot: DocumentSnapshot(
                id: UUID(),
                revision: 0,
                text: text
            ),
            range: ByteRange(0, text.byteCount),
            font: font,
            width: 1_000_000,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true
        )
        let origin = sample.caret(at: 0)
        let advance = sample.caret(at: 1).minX - origin.minX
        let valid =
            advance.isFinite && advance > 0 && advance <= 4096
            && (0...95).allSatisfy {
                let point = sample.caret(at: $0)
                return abs(point.minX - origin.minX - CGFloat($0) * advance) < 0.01
                    && abs(point.minY - origin.minY) < 0.01
            }
        if advances.count >= 32 {
            advances.removeAll()
        }
        if rejected.count >= 32 {
            rejected.removeAll()
        }
        if valid {
            advances[font] = advance
            return advance
        }
        rejected.insert(font)
        return nil
    }
}
