import Foundation

public struct PreparedClipboardCut: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：剪切在发布剪贴板前完整准备删除，原完整选择作为唯一撤销来源。
    /// 参数说明:
    /// - snapshot: 与复制载荷完全相同的原正文和选择。
    /// - copied: 当前来源已准备的复制结果。
    /// - rectangularTargets: 矩形的精确 Tab 两侧与虚拟目标，普通选择不得提供。
    /// - deadline: 复制与删除准备共用的截止。
    /// - permit: 本轮仍有准备资格。
    /// 返回：完整删除事务，尚未修改正文或系统剪贴板。
    public init(
        snapshot: DocumentSnapshot,
        copied: PreparedClipboardCopy,
        rectangularTargets: [SelectionInsertionTarget]? = nil,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            copied.sourceID == snapshot.id, copied.sourceRevision == snapshot.revision,
            copied.sourceSelection == snapshot.selectionGeneration
        else {
            throw NateError.message("剪切需要原完整选择和控制身份。")
        }
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        if let range = copied.copiedLineRange {
            guard case .stream = original.shape, rectangularTargets == nil,
                original.entries.allSatisfy({
                    $0.selection.range.isEmpty
                }),
                range
                    == snapshot.text.lineRange(snapshot.text.lineNumber(at: original.primary.selection.head))
            else {
                throw NateError.message("整行剪切的来源与复制计划不一致。")
            }
            let after = try SelectionState(
                entries: [
                    SelectionEntry(
                        id: original.primaryID,
                        selection: TextSelection(anchor: range.lower, head: range.lower)
                    )
                ],
                primaryID: original.primaryID
            )
            transaction = try PreparedTransaction(
                snapshot: snapshot,
                edits: [TextEdit(range, "")],
                selectionStateAfter: after,
                name: "剪切整行",
                permit: allowed
            )
        }
        else if case .rectangle(let shape) = original.shape {
            if shape.zeroWidth {
                transaction = try PreparedTextInsertion(
                    snapshot: snapshot,
                    value: "",
                    name: "剪切矩形",
                    permit: allowed
                ).transaction
                try budget.check()
                return
            }
            guard let targets = rectangularTargets,
                Set(targets.map(\.id)) == Set(original.entries.map(\.id)),
                targets.allSatisfy({
                    $0.text.isEmpty
                })
            else {
                throw NateError.message("矩形剪切缺少全部真实列的删除意图。")
            }
            transaction = try PreparedSelectionInsertion(
                snapshot: snapshot,
                targets: targets,
                name: "剪切矩形",
                permit: allowed
            ).transaction
        }
        else {
            guard rectangularTargets == nil else {
                throw NateError.message("普通剪切不能使用矩形布局。")
            }
            transaction = try PreparedTextInsertion(
                snapshot: snapshot,
                value: "",
                name: "剪切",
                permit: allowed
            ).transaction
        }
        try budget.check()
    }
}
