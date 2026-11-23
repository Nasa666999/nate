import AppKit
import NateCore

extension EditorView {
    /// 业务作用：主执行域只计算真实列边缘，临时删除和排版均不发布原文档状态。
    /// 参数说明:
    /// - content: 同一动作已经准备的完整真实内容。
    /// - deadline: 读取、解码和布局共用的截止。
    /// 返回：普通多目标为空；矩形输入返回完整布局，无法证明字形或容量时整体失败。
    func clipboardBlockLayout(
        _ content: ClipboardPasteContent,
        deadline: ContinuousClock.Instant
    ) async throws -> ClipboardBlockLayout? {
        try requireCurrentRectangleLayout()
        guard let state = viewSelectionState, state == document.selectionState,
            selectionStateRevision == document.revision
        else {
            throw NateError.message("剪贴板布局缺少当前完整选择证据。")
        }
        let payloadIsRectangle: Bool
        if case .rectangle = content.payload.shape {
            payloadIsRectangle = true
        }
        else {
            payloadIsRectangle = false
        }
        let source: EditorView
        let selected: [SelectionEntry]
        let removal: ByteRange?
        let x: Double
        let originalShape: RectangleSelectionShape?
        switch state.shape {
        case .stream:
            guard payloadIsRectangle else {
                return nil
            }
            let normalized = try state.normalized(in: document.text)
            guard normalized.entries.count == 1 else {
                return nil
            }
            let primary = normalized.primary
            let range = primary.selection.range
            removal = range.isEmpty ? nil : range
            let base = range.isEmpty ? document.text : try document.text.replacing(range, with: "")
            let temporary = EditorView(document: DocumentBuffer(text: base, format: document.format))
            temporary.font = font
            temporary.copyFontZoom(from: self)
            temporary.tabSettings = tabSettings
            temporary.language = language
            temporary.userLanguage = userLanguage
            temporary.editorTheme = editorTheme
            temporary.wrapLines = wrapLines
            temporary.geometryLayoutWidth = nativeBodyLayoutWidth
            temporary.showSymbols = showSymbols
            temporary.rtl = rtl
            temporary.appearance = effectiveAppearance
            temporary.refresh()
            source = temporary
            selected = [
                SelectionEntry(
                    id: primary.id,
                    selection: TextSelection(
                        anchor: range.lower,
                        head: range.lower,
                        virtualColumn: primary.selection.virtualColumn
                    )
                )
            ]
            try await temporary.prepareGeometrySyntax(
                row: base.lineNumber(at: range.lower),
                lastRow: min(
                    base.lineCount - 1,
                    base.lineNumber(at: range.lower) + content.documentValues.count - 1
                ),
                deadline: deadline
            )
            x = try temporary.rectangleCaretX(at: range.lower, virtual: primary.selection.virtualColumn)
            originalShape = nil
        case .rectangle(let shape):
            source = self
            selected = state.entries.sorted {
                $0.selection.range.lower < $1.selection.range.lower
            }
            removal = nil
            x = min(shape.anchorX, shape.headX)
            originalShape = shape
        }
        let count = payloadIsRectangle ? max(selected.count, content.documentValues.count) : selected.count
        guard count <= ClipboardLimits.fragments, x.isFinite, (0...1_000_000_000).contains(x) else {
            throw NateError.message("块粘贴的真实行数或视觉列超过限制。")
        }
        let paired = payloadIsRectangle || content.documentValues.count == selected.count
        guard let last = selected.last else {
            throw NateError.message("块粘贴没有完整选择行。")
        }
        let lastRow = source.document.text.lineNumber(at: last.selection.range.lower)
        let lastNeededRow = min(
            source.document.text.lineCount - 1,
            lastRow + max(0, count - selected.count)
        )
        var targets: [ClipboardBlockTarget] = []
        var tabX: Double?
        for index in 0..<count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("块粘贴的原生边缘计算超过时间预算。")
            }
            let value =
                paired
                ? (index < content.documentValues.count ? content.documentValues[index] : "")
                : content.plainText
            let targetRow =
                index < selected.count
                ? source.document.text.lineNumber(at: selected[index].selection.range.lower)
                : lastRow + index - selected.count + 1
            if targetRow < source.document.text.lineCount {
                try await source.prepareGeometrySyntax(
                    row: targetRow,
                    lastRow: lastNeededRow,
                    deadline: deadline
                )
            }
            if index == 0, originalShape == nil {
                // 普通选择的起点具有明确字节身份，软换行或原生近似命中不能把它移动到其它字形。
                let first = selected[0].selection
                targets.append(
                    ClipboardBlockTarget(
                        range: first.range,
                        leadingSpaces: value.isEmpty ? 0 : first.virtualColumn,
                        virtualColumn: value.isEmpty ? first.virtualColumn : 0
                    )
                )
                continue
            }
            let entry: SelectionEntry
            let shape: RectangleSelectionShape
            if index < selected.count, let originalShape {
                entry = selected[index]
                shape = originalShape
            }
            else {
                let row = lastRow + index - selected.count + 1
                if row >= source.document.text.lineCount {
                    break
                }
                let point = try source.rectangleHit(row: row, x: x)
                let body = source.document.text.lineRange(row, includeEnding: false)
                let end = try source.rectangleCaretX(at: body.upper, virtual: 0)
                let virtual =
                    point == body.upper
                    ? max(
                        0,
                        (x - end) / source.rectangleColumnWidth(at: body.upper)
                    ) : 0
                guard virtual.isFinite, virtual <= 1_000_000 else {
                    throw NateError.message("块粘贴定位超过一百万空白列。")
                }
                entry = SelectionEntry(
                    selection: TextSelection(
                        anchor: point,
                        head: point,
                        virtualColumn: Int(virtual.rounded())
                    )
                )
                shape = try RectangleSelectionShape(
                    anchorX: x,
                    headX: x,
                    zeroWidth: true,
                    edges: [
                        SelectionVirtualEdge(selectionID: entry.id, leadingColumns: Int(virtual.rounded()))
                    ]
                )
            }
            let prepared = try source.clipboardBlockTarget(entry, shape: shape, value: value)
            if index == 0 {
                tabX = prepared.tabX
            }
            targets.append(prepared.target)
        }
        let padding =
            x
            / max(
                1,
                Double((" " as NSString).size(withAttributes: [.font: source.defaultVirtualSpaceFont]).width)
            )
        guard padding.isFinite, (0...1_000_000).contains(padding), ContinuousClock.now < deadline else {
            throw NateError.message("块粘贴新行空白或计算时间超过限制。")
        }
        return ClipboardBlockLayout(
            baseRemoval: removal,
            targets: targets,
            additionalRows: count - targets.count,
            newRowPadding: Int(padding.rounded()),
            originTabX: tabX,
            layoutContext: source.currentRectangleLayoutContext,
            originProjection: originalShape?.edges.first(where: {
                $0.selectionID == selected[0].id
            })?.projection
        )
    }
}
