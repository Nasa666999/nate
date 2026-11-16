import AppKit
import NateCore
import NateSyntax

@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
    public var document: DocumentBuffer
    public var language: LanguageDefinition?
    public var onChange: (() -> Void)?
    public var onSelection: (() -> Void)?
    public var onCommand: ((String) -> Void)?
    public var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    public var showSymbols = false
    public var wrapLines = false
    public var rtl = false
    public var overwrite = false
    public var newline = "\n"
    public var gutterWidth: CGFloat = 62
    var layouts: [Int: LineLayout] = [:]
    var composition: CompositionSession?
    var dragAnchor: Int?
    var dragColumn: CGFloat?
    var blinkTimer: Timer?
    var caretVisible = true
    var hiddenLines: Set<Int> = []
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
        return (try? document.text.replacing(composition.originalRange, with: composition.text))
            ?? document.text
    }

    /// 业务作用：建立共享文档上的独立编辑视图及输入上下文。
    /// 参数说明:
    /// - document: 唯一正文与历史。
    /// 返回：可放入滚动容器的自定义原生编辑区域。
    public init(document: DocumentBuffer) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
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
        if composition?.revision != document.revision {
            composition = nil
        }
        layouts.removeAll()
        let viewport = enclosingScrollView?.contentSize ?? NSSize(width: 900, height: 600)
        setFrameSize(
            NSSize(
                width: max(viewport.width, frame.width),
                height: max(viewport.height, CGFloat(displayTree.lineCount) * lineHeight + 60)
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
        var state = SyntaxState()
        let tokens =
            language.map {
                SyntaxEngine.highlight(tree.text(in: range), base: range.lower, language: $0, state: &state)
            } ?? []
        let snapshot = DocumentSnapshot(id: document.id, revision: document.revision, text: tree)
        let layout = LineLayout(
            snapshot: snapshot,
            range: range,
            font: font,
            width: wrapLines
                ? max(80, (enclosingScrollView?.contentSize.width ?? 900) - gutterWidth - 16) : 1_000_000,
            tokens: tokens,
            rtl: rtl
        )
        if layouts.count > 512 {
            layouts.removeAll()
        }
        layouts[line] = layout
        return layout
    }

    /// 业务作用：绘制视口内正文、选区、行号、书签和输入法覆盖层。
    /// 参数说明:
    /// - dirtyRect: 系统要求重绘的区域。
    /// 返回：呈现当前已提交快照及独立预编辑，不改动文档。
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let tree = displayTree
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(tree.lineCount - 1, Int(dirtyRect.maxY / lineHeight) + 1)
        guard first <= last, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let active = tree.lineNumber(at: min(document.selections.first?.head ?? 0, tree.byteCount))
        for line in first...last {
            let y = CGFloat(line) * lineHeight + 8
            let layout = layoutLine(line)
            if line == active {
                NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
                NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight).fill()
            }
            for selection in document.selections where !selection.range.isEmpty && composition == nil {
                let a = max(selection.range.lower, layout.range.lower)
                let b = min(selection.range.upper, layout.range.upper)
                if a <= b, let ua = tree.utf16Offset(byte: a), let ub = tree.utf16Offset(byte: b) {
                    let start = layout.caret(at: ua - layout.originUTF16)
                    let end = layout.caret(at: ub - layout.originUTF16)
                    NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
                    NSRect(
                        x: gutterWidth + min(start.minX, end.minX),
                        y: y,
                        width: max(3, abs(end.minX - start.minX)),
                        height: lineHeight
                    ).fill()
                }
            }
            for fragment in layout.fragments {
                fragment.draw(
                    at: NSPoint(
                        x: gutterWidth + fragment.layoutFragmentFrame.minX,
                        y: y + fragment.layoutFragmentFrame.minY
                    ),
                    in: context
                )
            }
            if showSymbols {
                drawSymbols(line: line, layout: layout, y: y)
            }
            if composition == nil && caretVisible && window?.firstResponder === self {
                for selection in document.selections where tree.lineNumber(at: selection.head) == line {
                    if let offset = tree.utf16Offset(byte: selection.head) {
                        var rect = layout.caret(at: offset - layout.originUTF16)
                        rect.origin.x += gutterWidth
                        rect.origin.y += y
                        rect.size.height = lineHeight
                        NSColor.controlAccentColor.setFill()
                        rect.fill()
                    }
                }
            }
            if let composition, line == tree.lineNumber(at: composition.originalRange.lower) {
                let start = tree.utf16Offset(byte: composition.originalRange.lower) ?? 0
                let caret = layout.caret(at: start - layout.originUTF16 + composition.selected.location)
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
        NSRect(x: visibleRect.minX, y: dirtyRect.minY, width: gutterWidth - 8, height: dirtyRect.height)
            .fill()
        for line in first...last {
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
                    x: visibleRect.minX + gutterWidth - 16 - number.size().width,
                    y: CGFloat(line) * lineHeight + 9
                )
            )
            if document.bookmarks.contains(line) {
                NSColor.systemBlue.setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: visibleRect.minX + 4,
                        y: CGFloat(line) * lineHeight + 12,
                        width: 7,
                        height: 7
                    )
                ).fill()
            }
            if document.modifiedLines.contains(line) {
                NSColor.systemGreen.setFill()
                NSRect(
                    x: visibleRect.minX + gutterWidth - 10,
                    y: CGFloat(line) * lineHeight + 8,
                    width: 2,
                    height: lineHeight
                ).fill()
            }
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
    /// 参数说明: 无。
    /// 返回：只滚动视口，不移动正文光标。
    public func revealSelection() {
        guard let selection = document.selections.first else {
            return
        }
        let line = document.text.lineNumber(at: selection.head)
        let layout = layoutLine(line)
        let units = document.text.utf16Offset(byte: selection.head) ?? layout.originUTF16
        var rect = layout.caret(at: units - layout.originUTF16)
        rect.origin.x += gutterWidth
        rect.origin.y += CGFloat(line) * lineHeight + 8
        rect.size.height = lineHeight
        scrollToVisible(rect.insetBy(dx: -20, dy: -20))
    }
}
