import Foundation

public struct PreparedTransaction: Sendable {
    let documentID: UUID
    let revision: UInt64
    let before: PieceTree
    let after: PieceTree
    let edits: [TextEdit]
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
        selections = selectionsAfter
        format = formatAfter
        self.name = name
    }
}
