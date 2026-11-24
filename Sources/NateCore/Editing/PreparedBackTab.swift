import Foundation

public struct PreparedBackTab: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：在行首空白退一级，多行选择逐行退缩进，代码中的普通光标退到前一个 Tab 停靠位。
    /// 参数说明:
    /// - snapshot: 带稳定选择身份的实际正文。
    /// - settings: 当前语言的 Tab 停靠宽度与输入设置。
    /// - preparedColumns: 给独立普通光标复用的同源长行列证据。
    /// - permit: 本轮所有范围和事务仍有准备资格的检查。
    /// 返回：正文与选择同一次准备；权限、容量或字素失效时整批失败。
    public init(
        snapshot: DocumentSnapshot,
        settings: TabSettings,
        preparedColumns: [ASCIITabColumns] = [],
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard let original = snapshot.selectionState, case .stream = original.shape else {
            throw NateError.message("退 Tab 需要普通光标或选择，矩形边缘保持原状。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < deadline
        }
        let budget = SelectionPreparationBudget(permit: allowed)
        let text = snapshot.text
        // 行前缀会统一归并，同一行的重合选择仍需要各自的稳定身份与建立顺序。
        let state = try original.validated(in: text, permit: allowed)
        var columns = try LogicalColumnReader(
            text: text,
            tabWidth: settings.width,
            deadline: deadline,
            preparedColumns: preparedColumns,
            permit: allowed
        )
        var prefixBytes = 0
        var prefixes: [Int: ByteRange] = [:]
        var affected = IndexSet()
        var targets: [UUID: TextSelection] = [:]
        // 活动端按文档位置读取，结果仍按原建立顺序及主项发布。
        for entry in state.entries.sorted(by: { $0.selection.head < $1.selection.head }) {
            try budget.check()
            let selection = entry.selection
            let first = text.lineNumber(at: selection.range.lower)
            let last = text.lineNumber(at: selection.range.upper)
            if first < last {
                affected.insert(integersIn: LineIndentationEdits.rows(for: selection.range, in: text))
            }
            else {
                let prefix = try Self.prefix(
                    line: first,
                    text: text,
                    known: &prefixes,
                    consumed: &prefixBytes,
                    budget: budget
                )
                if selection.head <= prefix.upper, selection.virtualColumn == 0 {
                    affected.insert(first)
                    targets[entry.id] = TextSelection(anchor: prefix.upper, head: prefix.upper)
                }
                else {
                    targets[entry.id] = try columns.retreatToTabStop(from: selection)
                }
            }
            guard affected.count <= LineIndentationEdits.maximumLines else {
                throw NateError.message("退 Tab 只能同时处理十万行，原选择与正文保持原状。")
            }
        }
        var edits: [TextEdit] = []
        for line in affected {
            try budget.check()
            let range = try Self.prefix(
                line: line,
                text: text,
                known: &prefixes,
                consumed: &prefixBytes,
                budget: budget
            )
            if let edit = LineIndentationEdits.removal(in: range, text: text, width: settings.width) {
                edits.append(edit)
            }
        }
        let map = try PositionMap(edits: edits)
        let after = try state.entries.map { entry in
            try budget.check()
            let selected = targets[entry.id] ?? entry.selection
            return SelectionEntry(
                id: entry.id,
                selection: TextSelection(
                    anchor: try map.checkedMap(selected.anchor),
                    head: try map.checkedMap(selected.head),
                    virtualColumn: selected.virtualColumn
                )
            )
        }
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: SelectionState(entries: after, primaryID: state.primaryID),
            name: "退缩进",
            permit: allowed
        )
    }

    /// 业务作用：同一行的所有选择共享实际原空白范围，只允许缩进动作读取有限前缀。
    /// 参数说明:
    /// - line: 当前正文物理行。
    /// - text: 同一固定正文。
    /// - known: 这批动作核对过的行前缀。
    /// - consumed: 本轮累计原空白字节数。
    /// - budget: 选择及行扫描共用的执行资格。
    /// 返回：不包含行结束符或正文的空白范围，至多读取 1 MiB 累计前缀。
    private static func prefix(
        line: Int,
        text: PieceTree,
        known: inout [Int: ByteRange],
        consumed: inout Int,
        budget: SelectionPreparationBudget
    ) throws -> ByteRange {
        if let range = known[line] {
            return range
        }
        let row = text.lineRange(line, includeEnding: false)
        var end = row.lower
        while end < row.upper, let byte = text.byte(at: end), byte == 9 || byte == 32 {
            if consumed & 255 == 0 {
                try budget.check()
            }
            guard consumed < 1_048_576 else {
                throw NateError.message("退 Tab 的前导空白超过 1 MiB，未准备部分编辑。")
            }
            consumed += 1
            end += 1
        }
        let range = ByteRange(row.lower, end)
        known[line] = range
        return range
    }
}
