import AppKit
import NateCore
import NateSyntax

@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
    public var document: DocumentBuffer {
        didSet {
            if oldValue !== document {
                clipboard.cancel()
                // 文档生命周期改变后，旧候选和拖选不能沿用相同修订号写入另一个正文。
                composition = nil
                inputContext?.discardMarkedText()
                dismissCompletion()
                dragAnchor = nil
                dragColumn = nil
                dragRevision = nil
                dragSelectionID = nil
                dragAppending = false
                layouts.removeAll()
                hiddenLines.removeAll()
                syntaxTask?.cancel()
                syntaxGeneration = UUID()
                syntaxDocument = nil
                syntaxCache = [:]
                syntaxCheckpoints = [:]
                syntaxFailure = nil
                syntaxFailedLines = nil
                invalidateBracketAnalysis()
                markDisplayStatus = nil
                textHighlights.removeAll()
                textHighlightDisplayStatus = nil
                cancelSelectedTextHighlights()
            }
            if let state = document.selectionState {
                adoptViewSelectionState(state)
            }
            else {
                viewSelections = document.selections
            }
            observedRevision = document.revision
            projection.measured.removeAll()
            refresh()
        }
    }
    public var viewSelections = [TextSelection(anchor: 0, head: 0)] {
        didSet {
            if !publishingViewSelectionState {
                if oldValue != viewSelections {
                    synchronizeLegacyViewSelectionState()
                }
                if window?.firstResponder === self {
                    synchronizeDocumentSelectionState()
                }
            }
        }
    }
    public var onFocus: (() -> Void)?
    public internal(set) var selectionGeneration = UUID()
    public internal(set) var viewSelectionState: SelectionState?
    var selectionStateRevision: UInt64 = 0
    var publishingViewSelectionState = false
    public internal(set) var focusGeneration = UUID()
    public var selectedTextHighlightContext: (() -> SelectedTextHighlightContext?)?
    let selectedTextHighlights = SelectedTextHighlightRuntime()
    var observedRevision: UInt64 = 0
    var projection = VisualLineMap()
    var layoutMetrics: EditorLayoutMetrics?
    public var language: LanguageDefinition? {
        didSet {
            updateLanguageResource()
        }
    }
    var languageResource: Data?
    let brackets = BracketViewState()
    let folds = FoldViewState()
    public var bracketLimits = BracketAnalysisLimits() {
        didSet {
            invalidateBracketAnalysis()
        }
    }
    public var userLanguage: UDLDefinition? {
        didSet {
            if oldValue?.originalXML != userLanguage?.originalXML {
                invalidateSyntax()
            }
        }
    }
    public var onStatus: ((String) -> Void)?
    var syntaxTask: Task<Void, Never>?
    var syntaxTaskID: UUID?
    var syntaxGeneration = UUID()
    var syntaxDocument: UUID?
    var syntaxLanguage = ""
    var syntaxRevision: UInt64 = 0
    var syntaxCache: [Int: [SyntaxToken]] = [:]
    var syntaxCheckpoints: [Int: LexicalState] = [:]
    var syntaxFailure: String?
    var syntaxFailedLines: Range<Int>?
    public var onChange: (() -> Void)?
    public var onTextInput: ((String) -> Void)?
    public var onClipboardCapture: ((ClipboardPayload) -> Void)?
    public var onClipboardPaste: ((ClipboardPayload, Bool) -> Void)?
    public var copyLineWithoutSelection = true
    public var adaptClipboardLineEndings = false
    let clipboard = ClipboardRuntime()
    public var onSelection: (() -> Void)?
    public var onCommand: ((String) -> Void)?
    public var onOpenURLs: (([URL]) -> Void)?
    public var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            if oldValue != font {
                clipboard.cancel()
            }
        }
    }
    public var showSymbols = false
    public var wrapLines = false {
        didSet {
            if oldValue != wrapLines {
                clipboard.cancel()
            }
        }
    }
    public var rtl = false {
        didSet {
            if oldValue != rtl {
                clipboard.cancel()
            }
        }
    }
    public var overwrite = false
    public var newline: String {
        document.format.lineEnding.text
    }
    public var gutterWidth: CGFloat = 62
    var layouts: [Int: LineLayout] = [:]
    var composition: CompositionSession?
    var dragAnchor: Int?
    var dragColumn: CGFloat?
    var dragRevision: UInt64?
    var dragSelectionID: UUID?
    var dragAppending = false
    var blinkTimer: Timer?
    var caretVisible = true
    public internal(set) var markDisplayStatus: String?
    var textHighlights: [TextHighlightLayer: PreparedTextHighlights] = [:]
    public internal(set) var textHighlightDisplayStatus: String?
    var completionPanel: CompletionPanel?
    var hiddenLines = HiddenLineRanges()
    var lineHeight: CGFloat {
        ceil(font.ascender - font.descender + font.leading + 5)
    }
    public override var isFlipped: Bool {
        true
    }
    public override var acceptsFirstResponder: Bool {
        true
    }
    public var hasComposition: Bool {
        composition != nil
    }
    var displayTree: PieceTree {
        guard let composition, composition.revision == document.revision else {
            return document.text
        }
        // 候选前的虚拟定位只进入展示树，确认前的自动保存和撤销来源仍保持原正文。
        let displayed =
            String(repeating: " ", count: composition.virtualPadding) + composition.text
            + String(repeating: " ", count: composition.displaySuffix)
        return (try? document.text.replacing(composition.originalRange, with: displayed))
            ?? document.text
    }

    /// 业务作用：建立共享文档上的独立编辑视图及输入上下文。
    /// 参数说明:
    /// - document: 唯一正文与历史。
    /// 返回：可放入滚动容器的自定义原生编辑区域。
    public init(document: DocumentBuffer) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        if let state = document.selectionState {
            adoptViewSelectionState(state)
        }
        else {
            viewSelections = document.selections
        }
        observedRevision = document.revision
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Nate 文本编辑区")
        registerForDraggedTypes([.fileURL, .string])
    }

    /// 业务作用：正文视图只由工作区建立，不从归档产生独立缓冲区。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：使文档高度随逻辑行增长，布局缓存有界且不生成全文字形。
    /// 参数说明:
    /// - reveal: 是否显示当前光标；后台更新不抢视口。
    /// 返回：刷新呈现，不制造编辑或保存状态。
    public func refresh(reveal: Bool = false) {
        synchronizeBracketContext()
        if window?.firstResponder === self || reveal {
            if let state = document.selectionState {
                adoptViewSelectionState(state)
            }
            else {
                viewSelections = document.selections
            }
        }
        else {
            synchronizeViewSelectionRevision()
        }
        if observedRevision != document.revision {
            // 临时匹配仅属于原正文，不按普通锚点移动后冒充重新搜索的结果。
            textHighlights.removeAll()
            projection.measured.removeAll()
        }
        observedRevision = document.revision
        if let composition, composition.revision != document.revision {
            // 先通知输入上下文撤销旧组合；同步解除回调仍可看到失效修订并拒绝提交。
            inputContext?.discardMarkedText()
            self.composition = nil
        }
        layouts.removeAll()
        projection.count = displayTree.lineCount
        projection.defaultHeight = lineHeight
        rebuildFoldVisibility()
        gutterWidth = max(
            62,
            CGFloat(String(displayTree.lineCount).count) * max(6, font.pointSize * 0.65) + 42
        )
        let viewport = enclosingScrollView?.contentSize ?? NSSize(width: 900, height: 600)
        let metrics = EditorLayoutMetrics(
            font: font,
            width: viewport.width,
            gutter: gutterWidth,
            wrapping: wrapLines,
            rightToLeft: rtl
        )
        if !wrapLines || metrics != layoutMetrics {
            projection.measured.removeAll()
        }
        layoutMetrics = metrics
        setFrameSize(
            NSSize(
                width: max(
                    virtualRectangleWidth,
                    wrapLines ? viewport.width : max(viewport.width, frame.width)
                ),
                height: max(viewport.height, projection.y(of: displayTree.lineCount) + 60)
            )
        )
        needsDisplay = true
        if reveal {
            revealSelection()
        }
        inputContext?.invalidateCharacterCoordinates()
    }

    /// 业务作用：按可见逻辑行建立原生布局，限制缓存占用。
    /// 参数说明:
    /// - line: 真实逻辑行号。
    /// 返回：本视图私有的 TextKit 2 段落缓存。
    func layoutLine(_ line: Int) -> LineLayout {
        if let cached = layouts[line] {
            return cached
        }
        let tree = displayTree
        let range = tree.lineRange(line, includeEnding: false)
        let tokens = syntaxTokens(for: line)
        let snapshot = DocumentSnapshot(id: document.id, revision: document.revision, text: tree)
        let layout = LineLayout(
            snapshot: snapshot,
            range: range,
            font: font,
            width: wrapLines
                ? max(80, (enclosingScrollView?.contentSize.width ?? 900) - gutterWidth - 16) : 1_000_000,
            tokens: tokens,
            rtl: rtl,
            appearance: effectiveAppearance
        )
        if layouts.count > 512 {
            layouts.removeAll()
        }
        layouts[line] = layout
        if wrapLines {
            projection.measure(line, height: layout.height + 5)
        }
        return layout
    }

    /// 业务作用：绘制视口内正文、独立颜色标记、选区、行号、书签和输入法覆盖层。
    /// 参数说明:
    /// - dirtyRect: 系统要求重绘的区域。
    /// 返回：呈现当前已提交快照及独立预编辑，不改动文档。
    public override func draw(_ dirtyRect: NSRect) {
        prepareSelectedTextHighlights()
        prepareBracketAnalysis()
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let tree = displayTree
        let viewportAnchor = viewportAnchor()
        projection.measurementsChanged = false
        let drawing = dirtyRect.intersection(visibleRect)
        guard !drawing.isNull else {
            return
        }
        let first = projection.line(at: max(0, drawing.minY - 8))
        let last = min(tree.lineCount - 1, projection.line(at: drawing.maxY) + 1)
        guard first <= last, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let active = tree.lineNumber(at: min(primarySelection?.head ?? 0, tree.byteCount))
        let visibleLines = projection.visibleLines(in: first...last)
        var markBudget = 4096
        markDisplayStatus = nil
        textHighlightDisplayStatus = nil
        for line in visibleLines {
            let layout = layoutLine(line)
            let y = projection.y(of: line) + 8
            if line == active {
                NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
                NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight).fill()
            }
            drawDocumentMarks(in: layout, line: line, y: y, budget: &markBudget)
            drawTextHighlights(in: layout, line: line, y: y, budget: &markBudget)
            if !drawRectangularSelection(in: layout, line: line, y: y) {
                for selection in viewSelections where !selection.range.isEmpty && composition == nil {
                    let a = max(selection.range.lower, layout.range.lower)
                    let b = min(selection.range.upper, layout.range.upper)
                    if a <= b {
                        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
                        for rect in layout.selectionRects(ByteRange(a, b)) {
                            rect.offsetBy(dx: gutterWidth, dy: y).fill()
                        }
                    }
                }
            }
            drawVirtualRectangle(in: layout, line: line, y: y)
            drawBracketMatch(in: layout, y: y)
            for fragment in layout.fragments {
                context.saveGState()
                fragment.draw(
                    at: NSPoint(
                        x: gutterWidth + fragment.layoutFragmentFrame.minX,
                        y: y + fragment.layoutFragmentFrame.minY
                    ),
                    in: context
                )
                context.restoreGState()
            }
            if showSymbols {
                drawSymbols(line: line, layout: layout, y: y)
            }
            if composition == nil && caretVisible && window?.firstResponder === self {
                for selection in viewSelections where tree.lineNumber(at: selection.head) == line {
                    if let offset = tree.utf16Offset(byte: selection.head) {
                        var rect = layout.caret(at: offset - layout.originUTF16)
                        rect.origin.x += gutterWidth + selectionCaretOffset(for: selection)
                        rect.origin.y += y
                        rect.size.height = max(rect.height, lineHeight)
                        NSColor.controlAccentColor.setFill()
                        rect.fill()
                    }
                }
            }
            if let composition, line == tree.lineNumber(at: composition.originalRange.lower) {
                let start = tree.utf16Offset(byte: composition.originalRange.lower) ?? 0
                let caret = layout.caret(
                    at: start - layout.originUTF16 + composition.virtualPadding
                        + composition.selected.location
                )
                NSColor.controlAccentColor.setFill()
                NSRect(
                    x: gutterWidth + caret.minX,
                    y: y + lineHeight - 2,
                    width: max(8, CGFloat(composition.text.count) * font.maximumAdvancement.width),
                    height: 1
                ).fill()
            }
        }
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: visibleRect.minX, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height)
            .fill()
        for line in visibleLines {
            let number = NSAttributedString(
                string: "\(line + 1)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: max(9, font.pointSize - 2),
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            number.draw(
                at: NSPoint(
                    x: visibleRect.minX + gutterWidth - 25 - number.size().width,
                    y: projection.y(of: line) + 9
                )
            )
            if document.bookmarks.contains(line) {
                NSColor.systemBlue.setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: visibleRect.minX + 4,
                        y: projection.y(of: line) + 12,
                        width: 7,
                        height: 7
                    )
                ).fill()
            }
            if document.modifiedLines.contains(line) {
                NSColor.systemGreen.setFill()
                NSRect(
                    x: visibleRect.minX + gutterWidth - 21,
                    y: projection.y(of: line) + 8,
                    width: 2,
                    height: lineHeight
                ).fill()
            }
            drawFoldMarker(line: line)
        }
        let viewport = enclosingScrollView?.contentSize ?? bounds.size
        let height = max(viewport.height, projection.y(of: tree.lineCount) + 60)
        let contentWidth = layouts.values.reduce(viewport.width) {
            max($0, $1.width + gutterWidth + 20)
        }
        let width = wrapLines ? viewport.width : contentWidth
        if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
        if projection.measurementsChanged {
            restoreViewportAnchor(viewportAnchor)
            needsDisplay = true
        }
    }

    /// 业务作用：为不可见字符提供呈现标记，显示开关不改写文件。
    /// 参数说明:
    /// - line: 当前行。
    /// - layout: 本行原生布局。
    /// - y: 本行视图纵坐标。
    /// 返回：绘制空格、Tab 和行终止标记。
    func drawSymbols(line: Int, layout: LineLayout, y: CGFloat) {
        let text = displayTree.text(in: layout.range)
        var offset = 0
        for ch in text {
            if ch == " " || ch == "\t" {
                let position = layout.caret(at: offset)
                NSAttributedString(
                    string: ch == " " ? "·" : "→",
                    attributes: [
                        .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
                    ]
                ).draw(at: NSPoint(x: gutterWidth + position.minX, y: y))
            }
            offset += ch.utf16.count
        }
        let end = layout.caret(at: offset)
        NSAttributedString(
            string: "¬",
            attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        )
        .draw(at: NSPoint(x: gutterWidth + end.minX, y: y))
    }

    /// 业务作用：主动导航时显示当前选区，后台保存不会调用此入口。
    /// 参数说明:
    /// - selection: 明确需要显示的真实选区，为空时显示当前主选区。
    /// 返回：有效目标展开遮挡范围并滚动视口，不移动正文光标；非法字节位置保持原视口。
    public func revealSelection(_ selection: TextSelection? = nil) {
        guard let selection = selection ?? primarySelection,
            document.text.isBoundary(selection.anchor), document.text.isBoundary(selection.head)
        else {
            return
        }
        unfoldSelection(selection)
        let line = document.text.lineNumber(at: selection.head)
        let layout = layoutLine(line)
        let units = document.text.utf16Offset(byte: selection.head) ?? layout.originUTF16
        var rect = layout.caret(at: units - layout.originUTF16)
        rect.origin.x += gutterWidth + selectionCaretOffset(for: selection)
        rect.origin.y += projection.y(of: line) + 8
        rect.size.height = lineHeight
        if rect.maxX + 20 > frame.width {
            setFrameSize(NSSize(width: rect.maxX + 20, height: frame.height))
        }
        scrollToVisible(rect.insetBy(dx: -20, dy: -20))
    }

    /// 业务作用：焦点切换只发布该视图的选区，克隆视图保持自己的光标。
    /// 参数说明: 无。
    /// 返回：成为系统文本输入目标并通知窗口。
    public override func becomeFirstResponder() -> Bool {
        focusGeneration = UUID()
        synchronizeViewSelectionRevision()
        guard synchronizeDocumentSelectionState() else {
            return false
        }
        onFocus?()
        needsDisplay = true
        return true
    }

    /// 业务作用：焦点离开前收束有效输入法组合，候选窗口不能继续修改后台视图。
    /// 参数说明: 无。
    /// 返回：遵循原生焦点交接，已确认内容只进入一次事务。
    public override func resignFirstResponder() -> Bool {
        // 交出焦点即收回等待中的导航权，后续候选收束和焦点返回不能复活旧请求。
        focusGeneration = UUID()
        clipboard.cancel()
        finishComposition()
        dismissCompletion()
        // 焦点即使稍后返回同一光标，也不能重新执行此前尚未确认的导航意图。
        brackets.pending = nil
        folds.pending = nil
        needsDisplay = true
        return super.resignFirstResponder()
    }

    /// 业务作用：最后视图移出窗口时主动收回布局解析与浮层资源。
    /// 参数说明: 无。
    /// 返回：不再有解析任务或候选面板持有已关闭视图。
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeBracketFocus()
        if window == nil {
            clipboard.cancel()
            cancelSelectedTextHighlights()
            brackets.pending = nil
            folds.pending = nil
            brackets.task?.cancel()
            syntaxTask?.cancel()
            dismissCompletion()
        }
    }

    /// 业务作用：深浅外观变化后舍弃已解析颜色的段落缓存，各克隆视图分别响应。
    /// 参数说明: 无。
    /// 返回：重绘使用当前窗口外观，正文与选区保持原状态。
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}
