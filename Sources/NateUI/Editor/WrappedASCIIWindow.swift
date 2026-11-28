import AppKit
import NateCore

struct WrappedASCIIGeometry {
    let columns: Int
    let pitch: CGFloat
    let firstTop: CGFloat
    let firstBottom: CGFloat
}

@MainActor
final class WrappedASCIIWindow: LongLineProjection {
    private let snapshot: DocumentSnapshot
    private let range: ByteRange
    private let lineOriginUTF16: Int
    private let font: NSFont
    private let appearance: NSAppearance
    private let containerWidth: CGFloat
    private let theme: EditorThemeDefinition?
    private let language: String?
    private let fontZoomAdjustment: CGFloat
    private let advance: CGFloat
    private let metrics: WrappedASCIIGeometry
    private let wordIndex: ASCIIWordWrapIndex?
    private let hanFont: NativeHanLineFont?
    private let fixedByteWidth: Int
    let rowCount: Int
    private var rows: Range<Int>
    private var native: LineLayout
    private(set) var unavailableReason: String?

    var content: EditorContentManager {
        native.content
    }
    var manager: NSTextLayoutManager {
        native.manager
    }
    var renderedRange: ByteRange {
        native.range
    }
    var characterCount: Int {
        wordIndex?.characterCount ?? range.count / fixedByteWidth
    }
    var width: CGFloat {
        CGFloat(max(metrics.columns, wordIndex?.maximumRowLength ?? 0)) * advance
    }
    var height: CGFloat {
        if let variable = wordIndex?.variableOffset(at: rowCount) {
            return max(20, CGFloat(variable))
        }
        return max(20, metrics.firstBottom + CGFloat(rowCount - 1) * metrics.pitch)
    }
    private var variableWindowOffset: CGFloat?
    private var offsetY: CGFloat {
        variableWindowOffset ?? CGFloat(rows.lowerBound) * metrics.pitch
    }

    /// 业务作用：实际字体、原文和全部断行范围均有证据时才以原生窗口呈现超长软换行。
    /// 参数说明:
    /// - snapshot: 当前完整固定正文。
    /// - range: 本行的真实正文范围，排除原始物理行结束字节。
    /// - font: 当前视图字体，实际主题字体在下方求取。
    /// - appearance: 所属窗口当前外观。
    /// - containerWidth: 当前正文实际的软换行容器宽度。
    /// - theme: 当前编辑器的完整主题。
    /// - language: 当前绑定的原语言。
    /// - fontZoomAdjustment: 当前视图实际缩放差值。
    /// - tabWidth: 当前语言实际确认的制表宽度。
    /// - wordIndex: 含空格的同一原文及实际宽度已得到的完整断行索引。
    /// - ideographs: 可选的无制表全角字形证据，包含真实 Tab 的混排行从断行索引取得源证据。
    /// 返回：具备完整原生断行证据的初始窗口；不支持的内容、字体或宽度交回普通段落门禁。
    init?(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        appearance: NSAppearance,
        containerWidth: CGFloat,
        theme: EditorThemeDefinition?,
        language: String?,
        fontZoomAdjustment: CGFloat,
        tabWidth: Int = 4,
        wordIndex: ASCIIWordWrapIndex? = nil,
        ideographs: PlainHanLine? = nil
    ) {
        let actual = EditorThemePresentation.baseFont(
            font,
            theme: theme,
            language: language,
            adjustment: fontZoomAdjustment
        )
        let mixed = wordIndex?.mixedHanMetrics
        let han: NativeHanLineFont?
        if mixed != nil {
            guard ideographs.map({ $0.range == range && $0.matches(snapshot.text) }) != false,
                let resolved = NativeHanLineFont.resolve(from: actual)
            else {
                return nil
            }
            han = resolved
        }
        else if let ideographs {
            guard ideographs.range == range, ideographs.matches(snapshot.text),
                ideographs.characterCount * 3 == range.count,
                wordIndex?.usesFullWidthFont == true
                    || wordIndex == nil && ideographs.containsOnlyUnifiedIdeographs,
                let resolved = NativeHanLineFont.resolve(from: actual)
            else {
                return nil
            }
            han = resolved
        }
        else {
            guard wordIndex?.usesFullWidthFont != true else {
                return nil
            }
            han = nil
        }
        // 断行必须拥有完整原文与实际字体证据，基本汉字的真实步距来自已确认的级联字体。
        guard range.count > EditorNativeLayoutPolicy.maximumParagraphBytes,
            snapshot.text.byteCount <= EditorNativeLayoutPolicy.maximumDocumentBytes,
            containerWidth.isFinite, containerWidth > 0,
            let advance = (mixed == nil ? han?.advance : nil)
                ?? NativeMonospaceGeometry.uniformAdvance(actual, appearance: appearance),
            containerWidth / advance <= 8192, let lineOrigin = snapshot.text.utf16Offset(byte: range.lower)
        else {
            return nil
        }
        if let mixed {
            // 后台纵坐标和断点只属于同一容器与两种字体，重新定位前须确认原测量仍匹配。
            guard mixed.width == Double(containerWidth), mixed.asciiAdvance == Double(advance),
                han.map({ Double($0.advance) }) == mixed.hanAdvance
            else {
                return nil
            }
        }
        let byteWidth = han == nil ? 1 : 3
        let total = wordIndex?.characterCount ?? range.count / byteWidth
        let sample: ByteRange
        let expected: WrappedASCIIGeometry?
        let indexedRows: [ByteRange]?
        if let wordIndex {
            if let width = wordIndex.tabWidth {
                guard width == tabWidth,
                    NativeMonospaceGeometry.provesTabStops(
                        actual,
                        width: width,
                        advance: advance,
                        appearance: appearance
                    )
                else {
                    return nil
                }
            }
            if !wordIndex.narrowScalars.isEmpty,
                !NativeNarrowUnicodeFont.proves(
                    wordIndex.narrowScalars,
                    font: actual,
                    advance: advance,
                    appearance: appearance
                )
            {
                return nil
            }
            if !wordIndex.combiningPairs.isEmpty,
                !NativeNarrowUnicodeFont.provesCombining(
                    wordIndex.combiningPairs,
                    font: actual,
                    advance: advance,
                    appearance: appearance,
                    tabWidth: wordIndex.tabWidth
                )
            {
                return nil
            }
            guard
                let grid = Self.referenceGeometry(
                    font: actual,
                    width: containerWidth,
                    appearance: appearance,
                    hanFont: mixed == nil ? han : nil
                ),
                wordIndex.range == range, wordIndex.matches(snapshot.text, columns: grid.columns),
                let first = wordIndex.rows(startingAt: 0, count: 1)?.first
            else {
                return nil
            }
            sample = first
            indexedRows = [first]
            expected = grid
        }
        else {
            guard han != nil || snapshot.text.isAlphanumericASCII(in: range) else {
                return nil
            }
            let guess = max(1, Int(containerWidth / advance))
            sample = ByteRange(range.lower, range.lower + min(total, guess * 4) * byteWidth)
            indexedRows = nil
            expected = nil
        }
        let native = Self.layout(
            snapshot: snapshot,
            range: sample,
            font: font,
            appearance: appearance,
            width: containerWidth,
            theme: theme,
            language: language,
            fontZoomAdjustment: fontZoomAdjustment,
            hanFont: han,
            tabWidth: wordIndex?.tabWidth ?? 4
        )
        guard
            let metrics = native.uniformWrapping(
                advance: advance,
                expected: expected,
                indexedRows: indexedRows,
                tabWidth: wordIndex?.tabWidth,
                narrowLetters: wordIndex?.narrowScalars.isEmpty == false,
                combiningLetters: wordIndex?.combiningPairs.isEmpty == false,
                mixedHan: mixed
            )
        else {
            return nil
        }
        self.snapshot = snapshot
        self.range = range
        lineOriginUTF16 = lineOrigin
        self.font = font
        self.appearance = appearance
        self.containerWidth = containerWidth
        self.theme = theme
        self.language = language
        self.fontZoomAdjustment = fontZoomAdjustment
        self.advance = advance
        self.metrics = metrics
        self.wordIndex = wordIndex
        hanFont = han
        fixedByteWidth = byteWidth
        rowCount = wordIndex?.rowCount ?? (total - 1) / metrics.columns + 1
        // 只有末行也属于固定列边界时可复用试样窗口，避免将试样截断处冒用为完整长行的真实行末。
        let sampleCharacters = sample.count / byteWidth
        let completeSample = indexedRows != nil || sampleCharacters.isMultiple(of: metrics.columns)
        rows = completeSample ? 0..<(indexedRows?.count ?? sampleCharacters / metrics.columns) : 0..<0
        self.native = native
        if !completeSample {
            project(covering: 0...0)
        }
    }

    /// 业务作用：用同一真实等宽字体和容器取得视觉列与行距，供后台读原文计算字间断点。
    /// 参数说明:
    /// - font: 已根据实际主题和缩放选定的原生字体。
    /// - width: 当前原生正文容器的真实宽度。
    /// - appearance: 当前编辑视图的外观。
    /// - hanFont: 测量实际全角网格时采用的已确认级联字体。
    /// 返回：TextKit 实测的固定网格；字体或容器不能形成该网格时为空。
    static func referenceGeometry(
        font: NSFont,
        width: CGFloat,
        appearance: NSAppearance,
        hanFont: NativeHanLineFont? = nil
    ) -> WrappedASCIIGeometry? {
        guard width.isFinite, width > 0,
            let advance = hanFont?.advance
                ?? NativeMonospaceGeometry.uniformAdvance(font, appearance: appearance),
            width / advance <= 8192
        else {
            return nil
        }
        let size = max(1, Int(width / advance)) * 4
        let tree = PieceTree(String(repeating: hanFont == nil ? "A" : "中", count: size))
        let native = Self.layout(
            snapshot: DocumentSnapshot(id: UUID(), revision: 0, text: tree),
            range: ByteRange(0, tree.byteCount),
            font: font,
            appearance: appearance,
            width: width,
            theme: nil,
            language: nil,
            fontZoomAdjustment: 0,
            hanFont: hanFont
        )
        return native.uniformWrapping(advance: advance)
    }

    /// 业务作用：用实际视口的纵坐标推导原生行窗口，远处滚动不排版先前的全部字形。
    /// 参数说明:
    /// - viewport: 相对本逻辑行起点的实际可见矩形。
    /// 返回：可见视觉行获得完整投影，超过窗口限额时撤回坐标权限。
    func updateViewport(_ viewport: NSRect) {
        let visible = row(at: viewport.minY)...row(at: max(viewport.minY, viewport.maxY))
        project(covering: visible)
    }

    /// 业务作用：只在真实命中行所在的有界 TextKit 窗口解释横纵坐标。
    /// 参数说明:
    /// - point: 相对完整逻辑行的视图坐标。
    /// 返回：UTF-16 原位置；超出实际行底时采用文件行尾端点。
    func character(at point: NSPoint) -> Int {
        let line = row(at: point.y)
        project(covering: line...line)
        guard unavailableReason == nil, point.x.isFinite, point.y.isFinite else {
            return 0
        }
        if point.y >= height {
            return characterCount
        }
        return native.originUTF16 - lineOriginUTF16
            + native.character(at: NSPoint(x: point.x, y: point.y - offsetY))
    }

    /// 业务作用：真实软换行边界保留上游和下游视觉行的独立光标坐标。
    /// 参数说明:
    /// - local: 相对完整逻辑行的 UTF-16 端点。
    /// - downstream: 字符边缘请求使用下一个视觉行时为真。
    /// 返回：经原生确认的光标坐标；窗口无法验证时返回空矩形。
    func caret(at local: Int, downstream: Bool) -> NSRect {
        let position = min(characterCount, max(0, local))
        guard let byte = byte(at: position) else {
            return .zero
        }
        if byte <= renderedRange.lower || byte >= renderedRange.upper || unavailableReason != nil {
            let row: Int
            let prev: Int
            if let wordIndex {
                guard let first = wordIndex.row(at: byte, downstream: false),
                    let last = wordIndex.row(at: byte, downstream: true)
                else {
                    unavailableReason = "超长软换行缺少当前光标的真实原字节断点。"
                    return .zero
                }
                prev = first
                row = last
            }
            else {
                row = min(rowCount - 1, position / metrics.columns)
                prev = position > 0 && position.isMultiple(of: metrics.columns) ? max(0, row - 1) : row
            }
            project(covering: prev...row)
        }
        guard unavailableReason == nil else {
            return .zero
        }
        return native.caret(
            at: position - (native.originUTF16 - lineOriginUTF16),
            downstream: downstream && position < characterCount
        ).offsetBy(dx: 0, dy: offsetY)
    }

    /// 业务作用：将完整长行的真实插入位置还原为所属视觉行，保留断点两侧的位置。
    /// 参数说明:
    /// - offset: 逻辑行相对的 UTF-16 原位置。
    /// - downstream: 共享端点采用后面的视觉行时为真。
    /// 返回：对应视觉行，与本窗口已经排版的原字节位置一致。
    func visualRow(containing offset: Int, downstream: Bool) -> Int? {
        if let wordIndex {
            guard let byte = byte(at: offset) else {
                return nil
            }
            return wordIndex.row(at: byte, downstream: downstream)
        }
        let position = downstream ? offset : max(0, offset - 1)
        return min(rowCount - 1, position / metrics.columns)
    }

    /// 业务作用：跨越长行视口时先建立目标视觉行的原生段落，再取得真实插入端点。
    /// 参数说明:
    /// - row: 完整逻辑行内已确认的视觉行号。
    /// - x: 当前视图的像素横坐标。
    /// 返回：完整行 UTF-16 位置及当前视觉行前沿，原生证据不足时为空。
    func visualCaret(in row: Int, x: CGFloat) -> LineVisualCaret? {
        project(covering: row...row)
        guard unavailableReason == nil, let local = native.visualCaret(in: row - rows.lowerBound, x: x) else {
            return nil
        }
        return LineVisualCaret(
            offset: native.originUTF16 - lineOriginUTF16 + local.offset,
            atLeadingEdge: local.atLeadingEdge
        )
    }

    /// 业务作用：由当前真实字形投影正文选择，离开视口的文本恢复为核心原范围。
    /// 参数说明:
    /// - selection: 完整逻辑行使用的原字节选择范围。
    /// 返回：当前有界布局中的选择矩形。
    func selectionRects(_ selection: ByteRange) -> [NSRect] {
        let lower = max(selection.lower, renderedRange.lower)
        let upper = min(selection.upper, renderedRange.upper)
        guard unavailableReason == nil, lower < upper else {
            return []
        }
        return native.selectionRects(ByteRange(lower, upper)).map {
            $0.offsetBy(dx: 0, dy: offsetY)
        }
    }

    /// 业务作用：查找标记及辅助读取按同一视口内的实际原生行取得可见正文。
    /// 参数说明:
    /// - viewport: 相对完整逻辑行的真实视口。
    /// 返回：有界原字节范围，窗口外正文不复制到绘制层。
    func visibleByteRanges(in viewport: NSRect) -> [ByteRange] {
        guard unavailableReason == nil else {
            return []
        }
        return native.visibleByteRanges(in: viewport.offsetBy(dx: 0, dy: -offsetY))
    }

    /// 业务作用：在完整逻辑行的正确纵坐标呈现局部原生段落。
    /// 参数说明:
    /// - origin: 完整逻辑行在视图中的起点。
    /// - context: 实际绘制上下文。
    /// 返回：当前可见段落完成绘制，正文和布局之外的选择保持。
    func draw(at origin: NSPoint, in context: CGContext) {
        native.draw(at: NSPoint(x: origin.x, y: origin.y + offsetY), in: context)
    }

    /// 业务作用：明确选择前景使用原来的软换行容器及字距证明。
    /// 参数说明:
    /// - origin: 完整逻辑行当前绘制起点。
    /// - color: 主题指定的选择前景色。
    /// - context: 已裁剪为原生选择片段的上下文。
    /// 返回：只更改绘制前景。
    func drawForeground(at origin: NSPoint, color: NSColor, in context: CGContext) {
        native.drawForeground(at: NSPoint(x: origin.x, y: origin.y + offsetY), color: color, in: context)
    }

    /// 业务作用：先采用同一混排字形的实际累计高度；固定字体可用真实行距直接换算。
    /// 参数说明:
    /// - y: 相对完整逻辑行的原生纵坐标。
    /// 返回：合法范围内的视觉行号。
    private func row(at y: CGFloat) -> Int {
        guard y.isFinite else {
            return 0
        }
        if let variable = wordIndex?.variableRow(at: Double(y)) {
            return variable
        }
        let number = floor((y - metrics.firstBottom) / metrics.pitch) + 1
        return Int(min(CGFloat(rowCount - 1), max(0, number)))
    }

    /// 业务作用：用原正文换算长视觉行的实际插入字节，不把一个窄字母拆成两个光标位置。
    /// 参数说明:
    /// - character: 当前逻辑行内的 UTF-16 相对位置。
    /// 返回：同一完整逻辑行的绝对原字节端点，无效位置为空。
    private func byte(at character: Int) -> Int? {
        guard (0...characterCount).contains(character) else {
            return nil
        }
        if wordIndex?.narrowScalars.isEmpty == false || wordIndex?.mixedHanMetrics != nil {
            return snapshot.text.byteOffset(utf16: lineOriginUTF16 + character)
        }
        return range.lower + character * fixedByteWidth
    }

    /// 业务作用：从真实视觉行开始重新交付原生段落，复验字形后才撤换旧片段。
    /// 参数说明:
    /// - requested: 本次需要完整覆盖的真实视觉行范围。
    /// 返回：取得相关有界窗口或明确暂停，不使用部分测量提供新坐标。
    private func project(covering requested: ClosedRange<Int>) {
        if rows.contains(requested.lowerBound), rows.contains(requested.upperBound) {
            unavailableReason = nil
            return
        }
        let maximum =
            wordIndex == nil ? EditorNativeLayoutPolicy.maximumWindowCharacters / metrics.columns : 4096
        let needed = requested.count
        guard needed <= maximum else {
            unavailableReason = "超长软换行的视口超过 65536 个字形的容量，已暂停当前呈现。"
            return
        }
        let count = min(rowCount, min(maximum, max(8, needed + 12)))
        var first = min(rowCount - count, max(0, requested.lowerBound - (count - needed) / 2))
        var last = first + count
        let segment: ByteRange
        let indexedRows: [ByteRange]?
        if let wordIndex {
            var planned = wordIndex.rows(startingAt: first, count: count)
            if let current = planned, let begin = current.first, let end = current.last,
                end.upper - begin.lower > EditorNativeLayoutPolicy.maximumWindowCharacters
            {
                first = requested.lowerBound
                last = requested.upperBound + 1
                planned = wordIndex.rows(startingAt: first, count: needed)
            }
            guard let planned, let start = planned.first, let end = planned.last,
                end.upper - start.lower <= EditorNativeLayoutPolicy.maximumWindowCharacters
            else {
                unavailableReason = "超长软换行的视口超过 65536 个字形的容量，已暂停当前呈现。"
                return
            }
            indexedRows = planned
            segment = ByteRange(start.lower, end.upper)
        }
        else {
            indexedRows = nil
            segment = ByteRange(
                range.lower + first * metrics.columns * fixedByteWidth,
                range.lower + min(characterCount, last * metrics.columns) * fixedByteWidth
            )
        }
        let candidate = Self.layout(
            snapshot: snapshot,
            range: segment,
            font: font,
            appearance: appearance,
            width: containerWidth,
            theme: theme,
            language: language,
            fontZoomAdjustment: fontZoomAdjustment,
            hanFont: hanFont,
            tabWidth: wordIndex?.tabWidth ?? 4
        )
        // 不同片段都必须重现原来的断行端点和像素几何，失配时不会发布旧窗口之外的坐标。
        guard
            candidate.uniformWrapping(
                advance: advance,
                expected: metrics,
                indexedRows: indexedRows,
                tabWidth: wordIndex?.tabWidth,
                narrowLetters: wordIndex?.narrowScalars.isEmpty == false,
                combiningLetters: wordIndex?.combiningPairs.isEmpty == false,
                mixedHan: wordIndex?.mixedHanMetrics
            ) != nil
        else {
            unavailableReason = "超长软换行的原生断行位置无法确认，已暂停当前呈现。"
            return
        }
        let variable = wordIndex?.variableOffset(at: first)
        guard wordIndex?.mixedHanMetrics == nil || variable != nil else {
            unavailableReason = "超长软换行缺少当前原生窗口的纵坐标。"
            return
        }
        native = candidate
        rows = first..<last
        variableWindowOffset = variable.map { CGFloat($0) }
        unavailableReason = nil
    }

    /// 业务作用：在当前真实宽度下用 TextKit 排版实际原文片段，关闭会破坏已确认等距的字距和连字。
    /// 参数说明:
    /// - snapshot: 当前完整固定正文。
    /// - range: 当前有界原始字节段。
    /// - font: 当前视图源字体。
    /// - appearance: 当前视图的实际外观。
    /// - width: 所属视口采用的完整排版宽度。
    /// - theme: 当前主题。
    /// - language: 当前语言。
    /// - fontZoomAdjustment: 所属视图真实缩放差值。
    /// - hanFont: 纯基本统一汉字采用的已确认字体。
    /// - tabWidth: 该段落使用的完整原生制表设置。
    /// 返回：绑定原字节的真实 TextKit 软换行段落。
    private static func layout(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        appearance: NSAppearance,
        width: CGFloat,
        theme: EditorThemeDefinition?,
        language: String?,
        fontZoomAdjustment: CGFloat,
        hanFont: NativeHanLineFont? = nil,
        tabWidth: Int = 4
    ) -> LineLayout {
        LineLayout(
            snapshot: snapshot,
            range: range,
            font: font,
            fontZoomAdjustment: fontZoomAdjustment,
            width: width,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true,
            nativeHanFont: hanFont,
            tabWidth: tabWidth,
            theme: theme,
            language: language
        )
    }
}
