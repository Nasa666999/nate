import Foundation

public struct PreparedClipboardPaste: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：普通多选粘贴等量时按文档顺序配对，其余情况向每个目标插入全部普通文本。
    /// 参数说明:
    /// - snapshot: 带完整原选择与控制代次的正文。
    /// - content: 已完成换行适配与容量校验的实际输入。
    /// - deadline: 读取、解码和构建共同截止。
    /// - permit: 本轮仍具有准备资格。
    /// 返回：单一可撤销事务；矩形目标需要明确原生布局，不在此处猜测像素列。
    public init(
        snapshot: DocumentSnapshot,
        content: ClipboardPasteContent,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            case .stream = original.shape
        else {
            throw NateError.message("普通粘贴需要当前完整流选择，矩形必须准备真实列目标。")
        }
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        let normalized = try original.normalized(in: snapshot.text, permit: allowed)
        if case .rectangle = content.payload.shape, normalized.entries.count == 1 {
            throw NateError.message("矩形载荷向单个目标粘贴必须准备完整块布局。")
        }
        if case .lines = content.payload.shape,
            original.entries.allSatisfy({
                $0.selection.range.isEmpty
            })
        {
            let anchor = original.primary.selection.head
            let start = snapshot.text.lineRange(snapshot.text.lineNumber(at: anchor)).lower
            let inserted = content.plainText.utf8.count
            guard snapshot.text.byteCount <= 1024 * 1024 * 1024 - inserted else {
                throw NateError.message("整行粘贴后的正文超过 1 GiB。")
            }
            // 整行只插入主光标所在行之前，原光标随原正文向后移动，不跳到新行的中间。
            let after = try SelectionState(
                entries: [
                    SelectionEntry(
                        id: original.primaryID,
                        selection: TextSelection(
                            anchor: anchor + inserted,
                            head: anchor + inserted,
                            virtualColumn: original.primary.selection.virtualColumn
                        )
                    )
                ],
                primaryID: original.primaryID
            )
            transaction = try PreparedTransaction(
                snapshot: snapshot,
                edits: [TextEdit(ByteRange(start, start), content.plainText)],
                selectionStateAfter: after,
                name: "粘贴整行",
                permit: allowed
            )
        }
        else {
            let paired = content.documentValues.count == normalized.entries.count
            var targets: [SelectionInsertionTarget] = []
            for (index, entry) in normalized.entries.enumerated() {
                try budget.check()
                let value = paired ? content.documentValues[index] : content.plainText
                targets.append(
                    SelectionInsertionTarget(
                        id: entry.id,
                        range: entry.selection.range,
                        text: value,
                        leadingSpaces: value.isEmpty ? 0 : entry.selection.virtualColumn,
                        virtualColumnAfter: value.isEmpty && entry.selection.range.isEmpty
                            ? entry.selection.virtualColumn : 0
                    )
                )
            }
            transaction = try PreparedSelectionInsertion(
                snapshot: snapshot,
                targets: targets,
                primaryID: normalized.primaryID,
                name: "粘贴",
                permit: allowed
            ).transaction
        }
        try budget.check()
    }
}
