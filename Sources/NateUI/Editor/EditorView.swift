import AppKit
import NateCore
import NateSyntax

@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
    public var document: DocumentBuffer {
        didSet {
            if oldValue !== document {
                clipboard.cancel()
                boundaries.cancelDelimiterSelection()
                // 文档生命周期改变后，旧候选和拖选不能沿用相同修订号写入另一个正文。
                composition = nil
                inputContext?.discardMarkedText()
                dismissCompletion()
                dragAnchor = nil
                dragColumn = nil
                dragRevision = nil
                dragSelectionID = nil
                dragAppending = false
                dropIntent = nil
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
                referenceGuideStatus = nil
                modificationDisplayStatus = nil
                textLinks.reset()
                toolTip = nil
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
                if window?.isKeyWindow == true, window?.firstResponder === self {
                    synchronizeDocumentSelectionState()
                }
            }
        }
    }
    public var onFocus: (() -> Void)?
    public var usesDefaultKeyboardRoutes = true
    let boundaries = EditorBoundaryRuntime()
    public internal(set) var selectionGeneration = UUID()
    public internal(set) var viewSelectionState: SelectionState?
    var selectionStateRevision: UInt64 = 0
    var publishingViewSelectionState = false
    public internal(set) var focusGeneration = UUID()
    public var selectedTextHighlightContext: (() -> SelectedTextHighlightContext?)?
    let selectedTextHighlights = SelectedTextHighlightRuntime()
    let textLinks = EditorTextLinkRuntime()
    /// 业务作用：链接设置只改变派生页面及呈现，配置往返也撤销旧任务的点击资格。
    /// 参数说明: 无。
    /// 返回：完整设置改变时清除旧页并重新安排绘制，正文、输入法、选择及排版保持。
    public var textLinkSettings = TextLinkSettings() {
        didSet {
            if oldValue != textLinkSettings {
                textLinks.reset()
                toolTip = nil
                updateTrackingAreas()
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }
    /// 业务作用：工作区只读取当前视图的链接能力说明，不用其它克隆的失败掩盖本视口状态。
    /// 参数说明: 无。
    /// 返回：当前链接识别或绘制的说明，为空表示没有需要反馈的链接状态。
    public var textLinkStatus: String? {
        textLinks.status
    }
    var observedRevision: UInt64 = 0
    var projection = VisualLineMap()
    var layoutMetrics: EditorLayoutMetrics?
    public var language: LanguageDefinition? {
        didSet {
            updateLanguageResource()
        }
    }
    var languageResource: Data? {
        didSet {
            if oldValue != languageResource {
                updateRectangleStyleIdentity()
            }
        }
    }
    var rectangleStyleIdentity = ""
    var rectangleProjectionGeneration: UUID?
    var rectangleProjectionCache: [UUID: RectangleEditProjection] = [:]
    let brackets = BracketViewState()
    let folds = FoldViewState()
    public var bracketLimits = BracketAnalysisLimits() {
        didSet {
            invalidateBracketAnalysis()
        }
    }
    public var userLanguage: UDLDefinition? {
        didSet {
            if oldValue?.generation != userLanguage?.generation {
                // 同一 XML 的运行时规则或样式也可能改变，旧状态与视觉目标不能沿原名称继续取得权限。
                updateRectangleStyleIdentity()
                projection.measured.removeAll()
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
    public var onPairInput: ((PairInputCommand) -> Void)?
    public var onEditorCommand: ((EditorCommand) -> Void)?
    public var onClipboardCapture: ((ClipboardPayload) -> Void)?
    public var onClipboardPaste: ((ClipboardPayload, Bool) -> Void)?
    public var onClipboardCopy: ((Bool, Bool) -> Void)?
    public var copyLineWithoutSelection = true
    public var adaptClipboardLineEndings = false
    public var clipboardMarkupDecoder:
        (@Sendable (Data, ClipboardMarkupFormat, ContinuousClock.Instant) throws -> String)?
    {
        didSet {
            // 编码来源改变后旧解码不再拥有正文发布权，即使后来恢复相同资源也不能继续原粘贴。
            clipboard.cancel()
        }
    }
    let clipboard = ClipboardRuntime()
    /// 业务作用：复合编辑持有剪贴板动作身份，外来的复制、剪切或粘贴会撤销旧步骤的继续资格。
    /// 参数说明: 无。
    /// 返回：当前视图独立的剪贴板控制代次，不读取系统剪贴板内容。
    public var clipboardOperationGeneration: UUID {
        clipboard.generation
    }
    public var onSelection: (() -> Void)?
    public var onCommand: ((String) -> Void)?
    public var onOpenURLs: (([URL]) -> Void)?
    public var onOpenTextLink: ((EditorView, DocumentTextLink, DocumentTextLinkPage) -> Void)?
    public var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            if oldValue != font {
                clipboard.cancel()
            }
        }
    }
    public var showSymbols = false {
        didSet {
            if oldValue != showSymbols {
                // 控制序列显隐会改变实际字形宽度和软换行，统一撤销旧排版及依赖几何的操作资格。
                refresh(reveal: false)
            }
        }
    }
    public var editorTheme: EditorThemeSnapshot? {
        didSet {
            if oldValue?.identity != editorTheme?.identity {
                editorThemeDidChange()
            }
        }
    }
    public internal(set) var showIndentGuides = true
    public internal(set) var longLineColumn: Int?
    public internal(set) var referenceGuideStatus: String?
    public var showModificationHistory = true
    public internal(set) var modificationDisplayStatus: String?
    public var indentationSettings = IndentationSettings()
    public var pairInsertionSettings = PairInsertionSettings()
    public var tabSettings = TabSettings() {
        didSet {
            if oldValue != tabSettings {
                tabSettingsDidChange()
            }
        }
    }
    public internal(set) var tabSettingsGeneration = UUID()
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
    var confirmingComposition = false
    var dragAnchor: Int?
    var dragColumn: CGFloat?
    var dragRevision: UInt64?
    var dragSelectionID: UUID?
    var dragAppending = false
    var dropIntent: EditorDropIntent?
    var blinkTimer: Timer?
    var caretVisible = true
    public internal(set) var markDisplayStatus: String?
    var textHighlights: [TextHighlightLayer: PreparedTextHighlights] = [:]
    public internal(set) var textHighlightDisplayStatus: String?
    var completionPanel: CompletionPanel?
    var hiddenLines = HiddenLineRanges()
    var lineHeight: CGFloat {
        fontMetrics.height(
            font: font,
            definition: userLanguage,
            theme: editorTheme,
            language: language?.id
        )
    }
    let fontMetrics = UDLFontMetrics()
    var geometryLayoutWidth: CGFloat?
    public override var isFlipped: Bool {
        true
    }
    public override var acceptsFirstResponder: Bool {
        true
    }
    public var hasComposition: Bool {
        composition != nil
    }

    /// 业务作用：建立共享文档上的独立编辑视图及输入上下文。
    /// 参数说明:
    /// - document: 唯一正文与历史。
    /// 返回：可放入滚动容器的自定义原生编辑区域。
    public init(document: DocumentBuffer) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        updateRectangleStyleIdentity()
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
        if reveal || (window?.isKeyWindow == true && window?.firstResponder === self) {
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
            rightToLeft: rtl,
            tabWidth: tabSettings.width,
            showSequences: showSymbols,
            themeIdentity: editorTheme?.identity
        )
        if !wrapLines || metrics != layoutMetrics {
            projection.measured.removeAll()
        }
        if metrics != layoutMetrics {
            clipboard.cancel()
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
        window?.invalidateCursorRects(for: self)
    }

    /// 业务作用：按可见逻辑行建立原生布局，限制缓存占用。
    /// 参数说明:
    /// - line: 真实逻辑行号。
    /// 返回：本视图私有的 TextKit 2 段落缓存。
    func layoutLine(_ line: Int) -> LineLayout {
        let viewport = visibleRect.offsetBy(dx: -gutterWidth, dy: 0)
        if let cached = layouts[line] {
            cached.updateViewport(viewport)
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
            fontZoomAdjustment: fontZoomAdjustment,
            virtualSpaceFont: defaultVirtualSpaceFont,
            width: nativeBodyLayoutWidth,
            tokens: tokens,
            rtl: rtl,
            appearance: effectiveAppearance,
            viewport: wrapLines ? nil : viewport,
            tabWidth: tabSettings.width,
            showSequences: showSymbols,
            theme: editorTheme?.definition,
            language: language?.id
        )
        // 原生段落的字符与字形都占用缓存，不能仅按行数允许大量长段落同时保留。
        if layouts.count >= EditorNativeLayoutPolicy.maximumCachedLines
            || layouts.values.reduce(
                0,
                {
                    $0 + $1.content.rendered.length
                }
            ) > EditorNativeLayoutPolicy.maximumCachedCharacters - layout.content.rendered.length
        {
            layouts.removeAll()
        }
        layouts[line] = layout
        if wrapLines {
            projection.measure(line, height: layout.height + 5)
        }
        return layout
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
    /// 返回：候选成功确认后交接焦点；失败返回假并保留原输入视图，已确认内容只进入一次事务。
    public override func resignFirstResponder() -> Bool {
        // 交出焦点即收回等待中的导航权，后续候选收束和焦点返回不能复活旧请求。
        focusGeneration = UUID()
        boundaries.cancelDelimiterSelection()
        clipboard.cancel()
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return false
        }
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
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        observeBracketFocus()
        if window == nil {
            textLinks.reset()
            toolTip = nil
            boundaries.cancelDelimiterSelection()
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
