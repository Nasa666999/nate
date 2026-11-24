import AppKit
import NateCore

struct WrappedCaretColumn {
    let x: CGFloat
    let downstream: Bool
}

struct EditorWrappedCaretRun {
    let documentID: UUID
    let revision: UInt64
    let selection: UUID
    let layout: UUID
    let columns: [UUID: WrappedCaretColumn]
    let downstreamHeads: Set<Int>
}

extension EditorView {
    /// 业务作用：绘制、焦点揭示和系统候选使用同一视觉行的活动端亲和性。
    /// 参数说明:
    /// - head: 当前视图提交正文中的活动端原字节。
    /// 返回：当前实测键盘移动在共享断点选择后继视觉行时为真。
    func prefersWrappedCaretDownstream(at head: Int) -> Bool {
        currentWrappedCaretRun?.downstreamHeads.contains(head) == true
    }

    /// 业务作用：只在同一文档、选择和视觉规则中保留纵向按键的原横坐标。
    /// 参数说明: 无。
    /// 返回：当前真实视图可继续使用的纵向导航来源。
    private var currentWrappedCaretRun: EditorWrappedCaretRun? {
        guard wrapLines, composition == nil, let wrappedCaretRun, wrappedCaretRun.documentID == document.id,
            wrappedCaretRun.revision == document.revision, wrappedCaretRun.selection == selectionGeneration,
            wrappedCaretRun.layout == wideTabLayout.geometryGeneration
        else {
            return nil
        }
        return wrappedCaretRun
    }

    /// 业务作用：上下键先移动到相邻真实视觉行，再跨越当前折叠投影中的逻辑行。
    /// 参数说明:
    /// - direction: 上移为负，下移为正。
    /// - extend: 键盘选择扩展时保留所有原固定端。
    /// 返回：完整选择和亲和性一起发布；任一目标缺少排版或选择资格时保留所有原位置。
    func moveWrappedVertical(direction: Int, extend: Bool) -> Bool {
        guard direction == -1 || direction == 1, let state = viewSelectionState,
            selectionStateRevision == document.revision
        else {
            return false
        }
        do {
            let snapshot = document.snapshot
            let preceding = currentWrappedCaretRun
            var selections: [TextSelection] = []
            var columns: [UUID: WrappedCaretColumn] = [:]
            var downstream: Set<Int> = []
            for entry in state.entries {
                let original = entry.selection
                let target = try wrappedCaretTarget(
                    from: original.head,
                    direction: direction,
                    preferred: preceding?.columns[entry.id],
                    text: snapshot.text
                )
                selections.append(
                    TextSelection(anchor: extend ? original.anchor : target.head, head: target.head)
                )
                columns[entry.id] = target.column
                if target.column.downstream {
                    downstream.insert(target.head)
                }
            }
            // 先确认整批几何及当前选区的合法性，失败时保留原选择和原活动端。
            let prepared = try state.acceptingGeometries(selections)
            try setSelectionState(prepared)
            wrappedCaretRun = EditorWrappedCaretRun(
                documentID: snapshot.id,
                revision: snapshot.revision,
                selection: selectionGeneration,
                layout: wideTabLayout.geometryGeneration,
                columns: columns,
                downstreamHeads: downstream
            )
            needsDisplay = true
            revealSelection()
            onSelection?()
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：让短视觉行上的临时收束保留目标横坐标，后继较宽视觉行恢复真实列。
    /// 参数说明:
    /// - head: 当前选择活动端的原 UTF-8 字节。
    /// - direction: 已确认的单步纵向方向。
    /// - preferred: 前一次同来源移动的实际横坐标与亲和性。
    /// - text: 本轮全部光标共用的已提交正文。
    /// 返回：当前实际目标原字节及视觉端点；未确认时抛错并禁止发布部分选择。
    private func wrappedCaretTarget(
        from head: Int,
        direction: Int,
        preferred: WrappedCaretColumn?,
        text: PieceTree
    ) throws -> (head: Int, column: WrappedCaretColumn) {
        let physical = text.lineNumber(at: head)
        let current = layoutLine(physical)
        guard let units = text.utf16Offset(byte: head) else {
            throw NateError.invalidRange
        }
        let local = min(current.characterCount, units - current.originUTF16)
        let downstream = preferred?.downstream ?? false
        guard let visual = current.visualRow(containing: local, downstream: downstream) else {
            throw NateError.message(current.unavailableReason ?? "当前段落缺少实际视觉行。")
        }
        let x = preferred?.x ?? current.caret(at: local, downstream: downstream).minX
        if let reason = current.unavailableReason {
            throw NateError.message(reason)
        }
        let next = visual + direction
        let layout: LineLayout
        let row: Int
        if (0..<current.visualRowCount).contains(next) {
            layout = current
            row = next
        }
        else {
            let adjacent = projection.adjacentLine(to: physical, direction: direction)
            if adjacent == physical {
                return (head, WrappedCaretColumn(x: x, downstream: downstream))
            }
            layout = layoutLine(adjacent)
            row = direction < 0 ? layout.visualRowCount - 1 : 0
        }
        guard let target = layout.visualCaret(in: row, x: x) else {
            throw NateError.message(layout.unavailableReason ?? "相邻视觉行缺少实际插入位置。")
        }
        var targetUnits = layout.originUTF16 + target.offset
        while targetUnits > layout.originUTF16, text.byteOffset(utf16: targetUnits) == nil {
            targetUnits -= 1
        }
        guard let byte = text.byteOffset(utf16: targetUnits),
            layout.range.lower <= byte, byte <= layout.range.upper
        else {
            throw NateError.invalidRange
        }
        return (byte, WrappedCaretColumn(x: x, downstream: target.atLeadingEdge && byte < layout.range.upper))
    }
}
