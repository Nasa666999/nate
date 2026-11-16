import Foundation

public struct PreparedTransaction: Sendable {
    let documentID: UUID
    let revision: UInt64
    let before: PieceTree
    let after: PieceTree
    let edits: [TextEdit]
    let changes: [PositionChange]
    let selections: [TextSelection]?
    let format: DocumentFormat?
    let name: String

    /// 业务作用：在后台完成批量修改的范围校验和正文构建，主线程只发布完整结果。
    /// 参数说明:
    /// - snapshot: 修改前的不可变文档证据。
    /// - edits: 全部基于同一快照的修改意图。
    /// - selectionsAfter: 可选的最终选区。
    /// - formatAfter: 可选的最终编码和换行规则。
    /// - name: 撤销动作名称。
    /// 返回：未发布的完整事务；交叠、非法边界或取消时不改变任何文档。
    public init(
        snapshot: DocumentSnapshot,
        edits: [TextEdit],
        selectionsAfter: [TextSelection]? = nil,
        formatAfter: DocumentFormat? = nil,
        name: String = "编辑"
    ) throws {
        let ordered = edits.sorted {
            $0.range.lower == $1.range.lower
                ? $0.range.upper < $1.range.upper : $0.range.lower < $1.range.lower
        }
        var unique: [TextEdit] = []
        for (index, edit) in ordered.enumerated() {
            if index % 256 == 0 {
                try Task.checkCancellation()
            }
            guard edit.range.lower <= edit.range.upper, snapshot.text.isBoundary(edit.range.lower),
                snapshot.text.isBoundary(edit.range.upper)
            else {
                throw NateError.invalidRange
            }
            if let previous = unique.last {
                if edit.range == previous.range && edit.text.utf8.elementsEqual(previous.text.utf8) {
                    continue
                }
                guard previous.range.upper <= edit.range.lower,
                    !(previous.range.isEmpty && previous.range == edit.range)
                else {
                    throw NateError.overlappingEdits
                }
            }
            if !snapshot.text.bytes(in: edit.range).elementsEqual(edit.text.utf8) {
                unique.append(edit)
            }
        }
        var prepared = snapshot.text
        for (index, edit) in unique.reversed().enumerated() {
            if index % 256 == 0 {
                try Task.checkCancellation()
            }
            prepared = try prepared.replacing(edit.range, with: edit.text)
        }
        if let selectionsAfter {
            guard
                selectionsAfter.allSatisfy({
                    prepared.isBoundary($0.anchor) && prepared.isBoundary($0.head)
                })
            else {
                throw NateError.invalidRange
            }
        }
        documentID = snapshot.id
        revision = snapshot.revision
        before = snapshot.text
        after = prepared
        self.edits = unique
        changes = unique.map {
            PositionChange(range: $0.range, insertedByteCount: $0.text.utf8.count)
        }
        selections = selectionsAfter
        format = formatAfter
        self.name = name
    }

    /// 业务作用：完整载入的正文直接共享后台构建的树，不为重新载入再复制一次全文。
    /// 参数说明:
    /// - snapshot: 替换前的固定文档。
    /// - text: 后台已经完成校验和构建的正文。
    /// - selectionsAfter: 明确的结果选区。
    /// - formatAfter: 新正文的编码与换行规则。
    /// - name: 用户可理解的撤销动作。
    /// 返回：一个完整替换事务，正文不同时保留正反位置映射。
    public init(
        replacing snapshot: DocumentSnapshot,
        with text: PieceTree,
        selectionsAfter: [TextSelection],
        formatAfter: DocumentFormat,
        name: String
    ) throws {
        try Task.checkCancellation()
        guard
            selectionsAfter.allSatisfy({
                text.isBoundary($0.anchor) && text.isBoundary($0.head)
            })
        else {
            throw NateError.invalidRange
        }
        documentID = snapshot.id
        revision = snapshot.revision
        before = snapshot.text
        after = text
        edits = []
        changes =
            snapshot.text.byteEqual(to: text)
            ? []
            : [
                PositionChange(
                    range: ByteRange(0, snapshot.text.byteCount),
                    insertedByteCount: text.byteCount
                )
            ]
        selections = selectionsAfter
        format = formatAfter
        self.name = name
        try Task.checkCancellation()
    }
}
