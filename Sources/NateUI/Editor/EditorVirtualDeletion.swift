import AppKit
import NateCore

extension EditorView {
    /// 业务作用：纯虚拟矩形退格沿固定行的真实空格边缘重新投影，字号不同的各行仍保持同一薄矩形。
    /// 参数说明:
    /// - snapshot: 已确认的唯一正文与完整选择来源。
    /// - state: 当前完整稳定选择身份。
    /// - shape: 同一视图中已经复验的零宽矩形。
    /// - forward: 为真时保留虚拟位置，否则退回固定行的一列。
    /// - deadline: 本轮全部原生边缘计算的共同截止。
    /// 返回：只改变完整选择的事务，不插入空白、不删除正文，也不制造正文历史。
    func prepareVirtualRectangleDeletion(
        snapshot: DocumentSnapshot,
        state: SelectionState,
        shape: RectangleSelectionShape,
        forward: Bool,
        deadline: ContinuousClock.Instant
    ) throws -> PreparedTransaction {
        guard
            let anchor = state.entries.first(where: {
                $0.id == shape.anchorID
            }) ?? state.entries.first
        else {
            throw NateError.message("虚拟矩形缺少固定行，原选择保留。")
        }
        let x =
            forward
            ? shape.anchorX
            : try rectangleCaretX(
                at: anchor.selection.head,
                virtual: max(0, anchor.selection.virtualColumn - 1)
            )
        let provisional = try RectangleSelectionShape(
            anchorX: x,
            headX: x,
            zeroWidth: true,
            edges: shape.edges,
            anchorID: shape.anchorID,
            headID: shape.headID,
            layoutContext: shape.layoutContext
        )
        var targets: [SelectionInsertionTarget] = []
        var edges: [SelectionVirtualEdge] = []
        for entry in state.entries {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("虚拟矩形投影超过共同截止，原选择保留。")
            }
            // 原边缘必须仍具备同一字形证据；不能把异步字体变化当作一次合法的退格移动。
            try verifyRectangleProjection(rectangleSourceProjection(entry, shape: shape), for: entry)
            let row = snapshot.text.lineNumber(at: entry.selection.head)
            let end = snapshot.text.lineRange(row, includeEnding: false).upper
            let point = forward ? entry.selection.head : try rectangleHit(row: row, x: x)
            let columns =
                point == end
                ? max(0, (x - (try rectangleCaretX(at: end, virtual: 0))) / rectangleColumnWidth(at: end))
                : 0
            guard columns.isFinite, columns <= 1_000_000 else {
                throw NateError.message("虚拟矩形位置超过一百万列，原选择保留。")
            }
            let virtual = forward ? entry.selection.virtualColumn : Int(columns.rounded())
            let selection = TextSelection(anchor: point, head: point, virtualColumn: virtual)
            let actual = try rectangleSourceProjection(
                SelectionEntry(id: entry.id, selection: selection),
                shape: provisional
            )
            _ = try actual.validated(for: selection, in: snapshot.text)
            targets.append(
                SelectionInsertionTarget(
                    id: entry.id,
                    range: ByteRange(point, point),
                    text: "",
                    virtualColumnAfter: virtual
                )
            )
            edges.append(
                try SelectionVirtualEdge(
                    selectionID: entry.id,
                    leadingColumns: virtual,
                    projection: actual
                )
            )
        }
        let after = try RectangleSelectionShape(
            anchorX: x,
            headX: x,
            zeroWidth: true,
            edges: edges,
            anchorID: shape.anchorID,
            headID: shape.headID,
            layoutContext: shape.layoutContext
        )
        return try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: targets,
            shapeAfter: .rectangle(after),
            name: "列删除",
            permit: {
                ContinuousClock.now < deadline
            }
        ).transaction
    }
}
