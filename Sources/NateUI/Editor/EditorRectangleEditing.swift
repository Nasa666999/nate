import AppKit
import NateCore

private struct RectangleEditingEdge {
    let position: Int
    let tab: ByteRange?
    let offset: Int
    let columns: Int
}

extension EditorView {
    /// 业务作用：矩形输入只展开边缘实际涉及的 Tab，所有行的剩余空白与输入一次进入事务。
    /// 参数说明:
    /// - value: 用户确认的原始输入文字。
    /// - overwrite: 零宽矩形的单行输入是否覆盖行内一个完整字形或 Tab 内的一列。
    /// 返回：保留原完整选择作为撤销来源的事务；目标或布局失效时不发布中间选择。
    func prepareRectangularInput(_ value: String, overwrite: Bool) throws -> PreparedTransaction {
        let snapshot = document.snapshot
        guard let state = viewSelectionState, state == snapshot.selectionState,
            selectionStateRevision == snapshot.revision, case .rectangle(let shape) = state.shape
        else {
            throw NateError.message("矩形输入缺少当前完整选择证据。")
        }
        if value.isEmpty && shape.zeroWidth {
            return try PreparedTextInsertion(snapshot: snapshot, value: value).transaction
        }
        return try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: rectangularInsertionTargets(value, overwrite: overwrite)
        ).transaction
    }

    /// 业务作用：只在主执行域完成原生边缘计算，剪切和粘贴可把不可变目标交给后台构建正文。
    /// 参数说明:
    /// - value: 此轮每个目标接收的完整文字。
    /// - overwrite: 单行值是否覆盖零宽矩形中的既有列。
    /// 返回：全部真实字节替换及 Tab 保留空白；布局或选择失效时不返回部分目标。
    func rectangularInsertionTargets(_ value: String, overwrite: Bool = false) throws
        -> [SelectionInsertionTarget]
    {
        guard let state = viewSelectionState, state == document.selectionState,
            selectionStateRevision == document.revision, case .rectangle(let shape) = state.shape
        else {
            throw NateError.message("列目标缺少当前完整选择证据。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let replace = overwrite && !value.isEmpty && !value.utf8.contains(10) && !value.utf8.contains(13)
        var targets: [SelectionInsertionTarget] = []
        for entry in state.entries {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("矩形输入边缘准备超过两秒，原正文与选择保留。")
            }
            targets.append(
                try rectangleInsertionTarget(
                    entry,
                    shape: shape,
                    value: value,
                    padEmpty: false,
                    overwrite: replace
                )
            )
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("矩形输入边缘准备超过两秒，原正文与选择保留。")
        }
        return targets
    }

    /// 业务作用：矩形复制只提取实际选中的 Tab 列与真实原文，虚拟定位和尾部由原形态独立提供。
    /// 参数说明: 无。
    /// 返回：普通选择为空，矩形返回完整逐行投影；超时、取消或失效时保留原剪贴板与选择。
    func rectangularCopyProjections() throws -> [ClipboardCopyProjection]? {
        guard let state = viewSelectionState, case .rectangle(let shape) = state.shape else {
            return nil
        }
        guard state == document.selectionState, selectionStateRevision == document.revision else {
            throw NateError.message("矩形复制缺少当前完整选择证据。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var projections: [ClipboardCopyProjection] = []
        for entry in state.entries {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("矩形复制边缘准备超过两秒，原剪贴板保留。")
            }
            let row = document.text.lineNumber(at: entry.selection.range.lower)
            var a = try rectangleEditingEdge(row: row, x: shape.anchorX)
            var b = try rectangleEditingEdge(row: row, x: shape.headX)
            if a.position > b.position || a.position == b.position && a.offset > b.offset {
                swap(&a, &b)
            }
            if let tab = a.tab, a.tab == b.tab {
                projections.append(
                    ClipboardCopyProjection(
                        selectionID: entry.id,
                        range: ByteRange(tab.upper, tab.upper),
                        leadingSpaces: b.offset - a.offset
                    )
                )
            }
            else {
                let range = ByteRange(a.tab?.upper ?? a.position, b.tab?.lower ?? b.position)
                guard range.lower <= range.upper else {
                    throw NateError.message("矩形复制边缘不能确定完整原文顺序。")
                }
                projections.append(
                    ClipboardCopyProjection(
                        selectionID: entry.id,
                        range: range,
                        leadingSpaces: a.tab == nil ? 0 : a.columns - a.offset,
                        trailingSpaces: b.tab == nil ? 0 : b.offset
                    )
                )
            }
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("矩形复制边缘准备超过两秒，原剪贴板保留。")
        }
        return projections
    }

    /// 业务作用：块粘贴保留空行经过的未选中 Tab，只有实际输入或正宽替换才展开两侧列。
    /// 参数说明:
    /// - entry: 本行已明确的选择与虚拟定位。
    /// - shape: 此行实际采用的原生视觉边缘。
    /// - value: 当前真实载荷行，不包含末尾扩展分隔符。
    /// 返回：单行不可变边缘及空操作留在 Tab 内时的横坐标。
    func clipboardBlockTarget(
        _ entry: SelectionEntry,
        shape: RectangleSelectionShape,
        value: String
    ) throws -> (target: ClipboardBlockTarget, tabX: Double?) {
        if shape.zeroWidth, value.isEmpty {
            let row = document.text.lineNumber(at: entry.selection.range.lower)
            let edge = try rectangleEditingEdge(row: row, x: shape.headX)
            return (
                ClipboardBlockTarget(
                    range: ByteRange(edge.position, edge.position),
                    virtualColumn: entry.selection.virtualColumn
                ),
                edge.tab == nil ? nil : shape.headX
            )
        }
        let target = try rectangleInsertionTarget(
            entry,
            shape: shape,
            value: value,
            padEmpty: false,
            overwrite: false
        )
        return (
            ClipboardBlockTarget(
                range: target.range,
                leadingSpaces: target.leadingSpaces,
                trailingSpaces: target.trailingSpaces,
                virtualColumn: target.virtualColumnAfter
            ),
            nil
        )
    }

    /// 业务作用：候选覆盖层只计算主项的 Tab 两侧与虚拟定位空白，不提前改写已提交正文。
    /// 参数说明: 无。
    /// 返回：当前矩形主项的展示替换意图；普通选择为空，无法取得完整边缘时失败。
    func rectangularCompositionTarget() throws -> SelectionInsertionTarget? {
        guard let state = viewSelectionState, case .rectangle(let shape) = state.shape else {
            return nil
        }
        return try rectangleInsertionTarget(
            state.primary,
            shape: shape,
            value: "",
            padEmpty: true,
            overwrite: false
        )
    }

    /// 业务作用：零宽矩形逐项删除完整字形，Tab 内只移除一列；纯虚拟删除不展开空白并保留矩形。
    /// 参数说明:
    /// - forward: 为真时删除光标右侧，否则删除左侧。
    /// 返回：全部目标准备完成的原子事务；字形预算、布局或选择失效时保留原正文与完整状态。
    func prepareRectangularDeletion(forward: Bool) throws -> PreparedTransaction {
        let snapshot = document.snapshot
        guard let state = viewSelectionState, state == snapshot.selectionState,
            selectionStateRevision == snapshot.revision, case .rectangle(let shape) = state.shape,
            shape.zeroWidth
        else {
            throw NateError.message("列光标删除需要当前完整零宽矩形。")
        }
        let allVirtual = state.entries.allSatisfy {
            $0.selection.virtualColumn > 0
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var navigation = try GraphemeNavigation(text: snapshot.text)
        var targets: [SelectionInsertionTarget] = []
        var virtual: [UUID: Int] = [:]
        for entry in state.entries {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("列删除边缘准备超过两秒，全部选择保持原状。")
            }
            let target: SelectionInsertionTarget
            if entry.selection.virtualColumn > 0 {
                let column = max(0, entry.selection.virtualColumn - (forward ? 0 : 1))
                virtual[entry.id] = column
                target = SelectionInsertionTarget(
                    id: entry.id,
                    range: entry.selection.range,
                    text: "",
                    virtualColumnAfter: column
                )
            }
            else {
                let row = snapshot.text.lineNumber(at: entry.selection.head)
                let edge = try rectangleEditingEdge(row: row, x: shape.headX)
                if let tab = edge.tab {
                    target = SelectionInsertionTarget(
                        id: entry.id,
                        range: tab,
                        text: "",
                        leadingSpaces: edge.offset - (forward ? 0 : 1),
                        trailingSpaces: edge.columns - edge.offset - (forward ? 1 : 0)
                    )
                }
                else {
                    let range = try navigation.range(at: edge.position, forward: forward)
                    target = SelectionInsertionTarget(id: entry.id, range: range, text: "")
                }
            }
            targets.append(target)
        }
        let after: SelectionShape
        if allVirtual {
            let shift = forward ? 0 : rectangleColumnWidth
            let edges = try shape.edges.map {
                try SelectionVirtualEdge(
                    selectionID: $0.selectionID,
                    leadingColumns: virtual[$0.selectionID] ?? 0
                )
            }
            after = .rectangle(
                try RectangleSelectionShape(
                    anchorX: max(0, shape.anchorX - shift),
                    headX: max(0, shape.headX - shift),
                    zeroWidth: true,
                    edges: edges,
                    anchorID: shape.anchorID,
                    headID: shape.headID
                )
            )
        }
        else {
            after = .stream
        }
        return try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: targets,
            shapeAfter: after,
            name: "列删除"
        ).transaction
    }

    /// 业务作用：把一行的两个视觉边缘变成实际字节替换和 Tab 两侧保留空白，未选中的 Tab 字节保持原样。
    /// 参数说明:
    /// - entry: 原完整矩形中的稳定行选择。
    /// - shape: 同一视图中的完整视觉矩形。
    /// - value: 此行实际插入文字。
    /// - padEmpty: 候选展示即使尚无确认文字也定位到虚拟列。
    /// - overwrite: 零宽实际输入是否消耗一个既有列或完整字形。
    /// 返回：不发布正文的单行完整目标；字形或 Tab 空白证据不足时失败。
    private func rectangleInsertionTarget(
        _ entry: SelectionEntry,
        shape: RectangleSelectionShape,
        value: String,
        padEmpty: Bool,
        overwrite: Bool
    ) throws -> SelectionInsertionTarget {
        let row = document.text.lineNumber(at: entry.selection.range.lower)
        var a = try rectangleEditingEdge(row: row, x: shape.anchorX)
        var b = try rectangleEditingEdge(row: row, x: shape.headX)
        if a.position > b.position || a.position == b.position && a.offset > b.offset {
            swap(&a, &b)
        }
        var range = ByteRange(a.tab?.lower ?? a.position, b.tab?.upper ?? b.position)
        var leading = a.tab == nil ? 0 : a.offset
        var trailing = b.tab == nil ? 0 : b.columns - b.offset
        var virtual = 0
        if range.isEmpty, entry.selection.virtualColumn > 0 {
            if !value.isEmpty || padEmpty {
                leading = entry.selection.virtualColumn
            }
            else {
                virtual = entry.selection.virtualColumn
            }
        }
        if overwrite && shape.zeroWidth {
            if a.tab != nil && a.tab == b.tab {
                trailing = max(0, trailing - 1)
            }
            else if range.isEmpty && entry.selection.virtualColumn == 0 {
                let body = document.text.lineRange(row, includeEnding: false)
                if range.lower < body.upper {
                    var navigation = try GraphemeNavigation(text: document.text)
                    range = try navigation.range(at: range.lower, forward: true)
                    guard range.upper <= body.upper else {
                        throw NateError.invalidRange
                    }
                }
            }
        }
        return SelectionInsertionTarget(
            id: entry.id,
            range: range,
            text: value,
            leadingSpaces: leading,
            trailingSpaces: trailing,
            virtualColumnAfter: virtual
        )
    }

    /// 业务作用：只在视觉边缘位于 Tab 内部时记录可展开的列位置，其它文字继续使用完整字形边界。
    /// 参数说明:
    /// - row: 当前真实逻辑行。
    /// - x: 不含边栏的视觉横坐标。
    /// 返回：完整字节边界或 Tab 内按空格宽度取最近列的意图，尚不展开 Tab。
    private func rectangleEditingEdge(row: Int, x: Double) throws -> RectangleEditingEdge {
        let body = document.text.lineRange(row, includeEnding: false)
        let layout = layoutLine(row)
        let y = layout.caret(at: 0).midY
        let raw = min(
            body.upper,
            max(
                body.lower,
                bytePosition(at: NSPoint(x: CGFloat(x) + gutterWidth, y: projection.y(of: row) + 8 + y))
            )
        )
        let snapped = try rectangleHit(row: row, x: x)
        var candidates = [raw, snapped]
        for point in [raw, snapped] where point > body.lower && document.text.byte(at: point - 1) == 9 {
            candidates.append(point - 1)
        }
        for point in candidates where point < body.upper && document.text.byte(at: point) == 9 {
            guard let units = document.text.utf16Offset(byte: point) else {
                throw NateError.invalidRange
            }
            let first = layout.caret(at: units - layout.originUTF16)
            let last = layout.caret(at: units - layout.originUTF16 + 1)
            guard abs(first.midY - y) < max(1, lineHeight / 2), abs(last.midY - y) < max(1, lineHeight / 2),
                x > Double(min(first.minX, last.minX)) + 0.01,
                x < Double(max(first.minX, last.minX)) - 0.01
            else {
                continue
            }
            let span = Double(last.minX - first.minX)
            let measured = abs(span) / rectangleColumnWidth
            guard measured.isFinite, measured > 0, measured <= 1_000_000 else {
                throw NateError.message("Tab 视觉跨度超过一百万列，未展开部分空白。")
            }
            let columns = max(1, Int(measured.rounded()))
            let offset = min(
                columns,
                max(0, Int(((x - Double(first.minX)) / span * Double(columns)).rounded()))
            )
            if offset == 0 || offset == columns {
                return RectangleEditingEdge(
                    position: offset == 0 ? point : point + 1,
                    tab: nil,
                    offset: 0,
                    columns: 0
                )
            }
            return RectangleEditingEdge(
                position: point,
                tab: ByteRange(point, point + 1),
                offset: offset,
                columns: columns
            )
        }
        return RectangleEditingEdge(position: snapped, tab: nil, offset: 0, columns: 0)
    }
}
