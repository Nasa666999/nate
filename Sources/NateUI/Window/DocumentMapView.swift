import AppKit
import NateCore

@MainActor
final class DocumentMapView: NSView {
    private struct Source: Equatable, Sendable {
        let document: UUID
        let revision: UInt64
        let tabWidth: Int
    }

    private weak var editor: EditorView?
    private weak var observedClip: NSClipView?
    private weak var sourceDocument: DocumentBuffer?
    private var source: Source?
    private var dragSource: Source?
    private var operation: Task<Void, Never>?
    private(set) var overview: DocumentMapOverview?

    /// 业务作用：隔离文档地图的只读绘制对象，输入仍由所属实际编辑视图处理。
    /// 参数说明:
    /// - frame: 原生工具区域的起始矩形。
    /// 返回：采用从上到下文档顺序的原生地图控件。
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("文档地图")
        toolTip = "单击或拖动以滚动当前编辑视图"
    }

    /// 业务作用：地图必须使用当前窗口绑定的正文，禁止从旧控件归档推断可用来源。
    /// 参数说明:
    /// - coder: 系统归档来源。
    /// 返回：由工作区重新建立时才提供地图。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：原生地图释放时停止等待摘要与旧裁剪视图事件。
    /// 参数说明: 无。
    /// 返回：旧控件不再绘制正文位置，也不再跟随其它视图滚动。
    deinit {
        operation?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// 业务作用：让文档第一行对应面板的顶部，绘制和点击采用同一坐标。
    /// 参数说明: 无。
    /// 返回：使用向下增长的原生坐标。
    override var isFlipped: Bool {
        true
    }

    /// 业务作用：停靠、隐藏或浮动发生变化时更新真实裁剪视图关联。
    /// 参数说明: 无。
    /// 返回：可见地图恢复当前来源；已经移出的地图放弃未完成摘要。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update(for: editor)
    }

    /// 业务作用：当前地图只属于所属编辑视图、正文修订和 Tab 宽度。
    /// 参数说明:
    /// - editor: 所属窗口当前实际显示的编辑视图。
    /// 返回：需要时启动有界摘要，等待期间旧正文位置不接受点击。
    func update(for editor: EditorView?) {
        if self.editor !== editor {
            dragSource = nil
        }
        self.editor = editor
        guard let editor, window != nil, !isHiddenOrHasHiddenAncestor,
            let clip = editor.enclosingScrollView?.contentView
        else {
            // 先撤回未完成来源，再脱离裁剪视图，隐藏期间不能沿旧窗口继续交接滚动。
            if source != nil {
                clearOverview()
            }
            observe(nil)
            return
        }
        observe(clip)
        let document = editor.document
        let candidate = Source(
            document: document.id,
            revision: document.revision,
            tabWidth: editor.tabSettings.width
        )
        needsDisplay = true
        guard source != candidate || sourceDocument !== document else {
            return
        }
        clearOverview()
        source = candidate
        sourceDocument = document
        toolTip = "正在生成当前文档的地图"
        let tree = document.text
        operation = Task { [weak self, weak document] in
            do {
                try await Task.sleep(for: .milliseconds(25))
            }
            catch {
                return
            }
            let worker = Task.detached(priority: .utility) {
                DocumentMapOverview.make(tree: tree, tabWidth: candidate.tabWidth)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // 同名文件、原标签返回和复用窗口都可能发生，旧数据不能仅凭标题或路径重新取得显示资格。
            guard let self, let document, !Task.isCancelled, source == candidate,
                self.editor?.document === document, document.revision == candidate.revision,
                window != nil, !isHiddenOrHasHiddenAncestor
            else {
                return
            }
            operation = nil
            overview = result
            toolTip = result == nil ? "未能在期限内生成当前地图" : "单击或拖动以滚动当前编辑视图"
            needsDisplay = true
        }
    }

    /// 业务作用：撤销当前地图来源，迟到任务不再发布实际可点击的行。
    /// 参数说明: 无。
    /// 返回：没有来自先前文档的缩略图或待完成操作。
    private func clearOverview() {
        operation?.cancel()
        operation = nil
        source = nil
        sourceDocument = nil
        dragSource = nil
        overview = nil
        needsDisplay = true
    }

    /// 业务作用：地图只监听当前实际编辑裁剪视图。
    /// 参数说明:
    /// - clip: 当前可显示的正文裁剪区域；移除观察时为空。
    /// 返回：原视图的迟到通知不改变现有视口指示。
    private func observe(_ clip: NSClipView?) {
        guard observedClip !== clip else {
            return
        }
        if let existing = observedClip {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: existing
            )
        }
        observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipMoved(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
    }

    /// 业务作用：活动视图移动时重画位置框，正文摘要仍可复用。
    /// 参数说明:
    /// - notification: AppKit 发出的实际裁剪边界通知。
    /// 返回：只标记当前地图的绘制需求。
    @objc private func clipMoved(_ notification: Notification) {
        needsDisplay = true
    }

    /// 业务作用：绘制有限的正文形态及真实视口框，使用当前正文视图的主题颜色。
    /// 参数说明:
    /// - dirtyRect: AppKit 当前请求的更新区域。
    /// 返回：地图不排版整份文件，尚未取得当前摘要时只显示底色。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let theme = editor?.editorTheme?.definition
        let appearance = editor?.effectiveAppearance ?? effectiveAppearance
        let language = editor?.language?.id
        EditorThemePresentation.color(
            .background,
            fallback: .textBackgroundColor,
            theme: theme,
            appearance: appearance,
            language: language
        ).setFill()
        dirtyRect.fill()
        guard let overview, let chart = chartBounds, sourceDocument === editor?.document else {
            return
        }
        let rowHeight = chart.height / CGFloat(overview.rows.count)
        let columnWidth = chart.width / CGFloat(DocumentMapOverview.maximumColumns)
        EditorThemePresentation.color(
            .foreground,
            fallback: .textColor,
            theme: theme,
            appearance: appearance,
            language: language
        ).withAlphaComponent(0.62).setFill()
        for (index, row) in overview.rows.enumerated() {
            let y = chart.minY + CGFloat(index) * rowHeight
            for range in row {
                NSRect(
                    x: chart.minX + CGFloat(range.lowerBound) * columnWidth,
                    y: y,
                    width: CGFloat(range.count) * columnWidth,
                    height: max(0.4, rowHeight * 0.66)
                ).fill()
            }
        }
        if let viewport = viewportBounds {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            viewport.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// 业务作用：稀疏短文档保持紧凑行距，长文档的真实全量逻辑位置映射到工具高度。
    /// 参数说明: 无。
    /// 返回：实际正文缩略图矩形，面板没有可绘制空间时为空。
    private var chartBounds: NSRect? {
        guard let overview, bounds.width > 16, bounds.height > 16 else {
            return nil
        }
        let area = bounds.insetBy(dx: 8, dy: 8)
        return NSRect(
            x: area.minX,
            y: area.minY,
            width: area.width,
            height: min(area.height, max(16, CGFloat(overview.rows.count) * 2.5))
        )
    }

    /// 业务作用：根据当前编辑器实际裁剪范围指示地图中的逻辑行位置。
    /// 参数说明: 无。
    /// 返回：合法的视口框，任何身份冲突或隐藏控件均为空。
    var viewportBounds: NSRect? {
        guard let overview, let chart = chartBounds, let editor, sourceDocument === editor.document,
            let lines = editor.documentMapVisibleLines()
        else {
            return nil
        }
        let unit = chart.height / CGFloat(overview.lineCount)
        let viewport = NSRect(
            x: chart.minX,
            y: chart.minY + unit * CGFloat(lines.lowerBound),
            width: chart.width,
            height: max(3, unit * CGFloat(lines.count))
        )
        return viewport.intersection(chart)
    }

    /// 业务作用：鼠标单击从地图真实位置滚动当前编辑视图。
    /// 参数说明:
    /// - event: 在当前原生工具区域发生的鼠标按下。
    /// 返回：采用与缩略图同一行映射，正文与选择保持原样。
    override func mouseDown(with event: NSEvent) {
        dragSource = source
        navigate(from: event)
    }

    /// 业务作用：在原生地图中拖动可连续滚动所属文档。
    /// 参数说明:
    /// - event: 当前地图的原生拖动位置。
    /// 返回：按当前显示位置滚动，逾界拖动收束到首尾。
    override func mouseDragged(with event: NSEvent) {
        if let dragSource, dragSource == source {
            navigate(from: event)
        }
    }

    /// 业务作用：释放鼠标后收束本次地图拖动，后续事件不能继续滚动。
    /// 参数说明:
    /// - event: 原生鼠标释放事件。
    /// 返回：清除本次拖动所持有的正文投影来源。
    override func mouseUp(with event: NSEvent) {
        dragSource = nil
    }

    /// 业务作用：滚动前重新核对实际窗口、文档、修订和候选状态。
    /// 参数说明:
    /// - event: 来自地图所在原生窗口的指针。
    /// 返回：仅沿当前有效投影移动视口，候选或过期位置不授予导航资格。
    private func navigate(from event: NSEvent) {
        guard let window, event.windowNumber == window.windowNumber, !isHiddenOrHasHiddenAncestor,
            let source, let editor, sourceDocument === editor.document, editor.document.id == source.document,
            editor.document.revision == source.revision, editor.tabSettings.width == source.tabWidth,
            !editor.hasMarkedText(), let overview, let chart = chartBounds
        else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, (point.y - chart.minY) / chart.height))
        let line = min(overview.lineCount - 1, Int(fraction * Double(overview.lineCount)))
        editor.centerDocumentMapLine(line)
        needsDisplay = true
    }
}
