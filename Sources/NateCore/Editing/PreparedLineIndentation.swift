import Foundation

public struct PreparedLineIndentation: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：显式增减缩进对全部实际涉及行只执行一次，菜单与宏均保留正文原字节及选择身份。
    /// 参数说明:
    /// - snapshot: 全部作用范围所属的固定正文和选择。
    /// - increasing: 为真时增加一级，否则移除首个停靠级别。
    /// - settings: 当前语言的实际 Tab 宽度与空白写入方式。
    /// - permit: 可继续准备原子事务的执行资格。
    /// 返回：没有作用行时保留合法选择；任一范围、容量或控制失效时整批拒绝。
    public init(
        snapshot: DocumentSnapshot,
        increasing: Bool,
        settings: TabSettings,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard let source = snapshot.selectionState else {
            throw NateError.message("调整行缩进需要实际正文上的完整选择。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < deadline
        }
        let budget = SelectionPreparationBudget(permit: allowed)
        let text = snapshot.text
        let selection = try source.validated(in: text, permit: allowed)
        var affected = IndexSet()
        for entry in selection.entries {
            try budget.check()
            affected.insert(integersIn: LineIndentationEdits.rows(for: entry.selection.range, in: text))
            // 固定总行数后才创建编辑，重合选择仍只处理每个物理前缀一次。
            guard affected.count <= LineIndentationEdits.maximumLines else {
                throw NateError.message("调整缩进最多处理十万行，原选择与正文保持原状。")
            }
        }
        let unit = LineIndentationEdits.unit(settings)
        if increasing, text.byteCount > 1_073_741_824 - affected.count * unit.utf8.count {
            throw NateError.message("增加缩进后的正文超过 1 GiB，未准备部分修改。")
        }
        var edits: [TextEdit] = []
        for line in affected {
            try budget.check()
            let row = text.lineRange(line, includeEnding: false)
            if increasing {
                edits.append(TextEdit(ByteRange(row.lower, row.lower), unit))
            }
            else if let removal = LineIndentationEdits.removal(in: row, text: text, width: settings.width) {
                edits.append(removal)
            }
        }
        let after: SelectionState?
        if case .stream = selection.shape {
            let positions = try PositionMap(edits: edits)
            let entries = try selection.entries.map { entry in
                try budget.check()
                let value = entry.selection
                return SelectionEntry(
                    id: entry.id,
                    selection: TextSelection(
                        anchor: try positions.checkedMap(value.anchor),
                        head: try positions.checkedMap(value.head),
                        virtualColumn: value.virtualColumn
                    )
                )
            }
            after = try SelectionState(entries: entries, primaryID: selection.primaryID)
        }
        else {
            // 行缩进改写矩形的视觉列，沿事务现有映射保存原形态并让用户重新确认视觉边缘。
            after = nil
        }
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: after,
            name: increasing ? "增加缩进" : "减少缩进",
            permit: allowed
        )
    }
}
