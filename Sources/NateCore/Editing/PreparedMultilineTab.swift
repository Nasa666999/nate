import Foundation

enum PreparedMultilineTab {
    /// 业务作用：真实跨行选区逐行增加一级，其它独立光标继续使用自己的输入规则，重合的行只缩进一次。
    /// 参数说明:
    /// - snapshot: 全部范围和旧选择所属的完整不可变正文。
    /// - selection: 当前正文的原选择身份与建立顺序。
    /// - settings: 当前语言的 Tab 宽度及实际写入方式。
    /// - overwrite: 未被跨行选择涵盖的空光标是否覆盖完整字素。
    /// - permit: 整批输入继续准备的资格。
    /// 返回：统一的原子事务；范围、容量、控制身份或任何独立目标不合法时不发布部分输入。
    static func transaction(
        snapshot: DocumentSnapshot,
        selection: SelectionState,
        settings: TabSettings,
        overwrite: Bool,
        permit: @escaping @Sendable () -> Bool
    ) throws -> PreparedTransaction {
        let text = snapshot.text
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < deadline
        }
        let budget = SelectionPreparationBudget(permit: allowed)
        _ = try selection.validated(in: text, permit: allowed)
        var affected = IndexSet()
        var singleLines: [(entry: SelectionEntry, line: Int)] = []
        var blockIDs: Set<UUID> = []
        for entry in selection.entries {
            try budget.check()
            let range = entry.selection.range
            let first = text.lineNumber(at: range.lower)
            let last = text.lineNumber(at: range.upper)
            if first < last {
                affected.insert(integersIn: LineIndentationEdits.rows(for: range, in: text))
                blockIDs.insert(entry.id)
            }
            else {
                singleLines.append((entry, first))
            }
            guard affected.count <= LineIndentationEdits.maximumLines else {
                throw NateError.message("跨行 Tab 最多处理十万行，原选择与正文保持原状。")
            }
        }
        var ordinary: [SelectionEntry] = []
        for item in singleLines {
            try budget.check()
            if affected.contains(item.line) {
                blockIDs.insert(item.entry.id)
            }
            else {
                ordinary.append(item.entry)
            }
        }
        let direct: PreparedTransaction?
        if let first = ordinary.first {
            let primary =
                ordinary.contains(where: { $0.id == selection.primaryID }) ? selection.primaryID : first.id
            // 该快照只给现有单点输入逻辑计算局部编辑，从生产文档发布的始终是原本完整选择上的总事务。
            let part = DocumentSnapshot(
                id: snapshot.id,
                revision: snapshot.revision,
                text: text,
                format: snapshot.format,
                selectionState: try SelectionState(entries: ordinary, primaryID: primary),
                selectionGeneration: snapshot.selectionGeneration
            )
            direct = try PreparedTabInsertion(
                snapshot: part,
                settings: settings,
                overwrite: overwrite,
                permit: allowed
            ).transaction
        }
        else {
            direct = nil
        }
        let unit = LineIndentationEdits.unit(settings)
        let inserted = affected.count * unit.utf8.count
        let intermediate = direct?.resultingText.byteCount ?? text.byteCount
        guard intermediate <= 1_073_741_824 - inserted,
            (direct?.edits.count ?? 0) <= LineIndentationEdits.maximumLines - affected.count
        else {
            throw NateError.message("跨行 Tab 的完整编辑超过正文或目标容量。")
        }
        var lineEdits: [TextEdit] = []
        var mappedLineEdits: [TextEdit] = []
        for line in affected {
            try budget.check()
            let start = text.lineStart(line)
            lineEdits.append(TextEdit(ByteRange(start, start), unit))
            if let direct {
                let mapped = try direct.positions.checkedMap(start)
                mappedLineEdits.append(TextEdit(ByteRange(mapped, mapped), unit))
            }
        }
        let merged = lineEdits + (direct?.edits ?? [])
        let totalPositions = try PositionMap(edits: merged)
        let linePositions = try PositionMap(edits: mappedLineEdits)
        let directSelection = direct?.selectionUpdate?.after
        let directResults = Dictionary(
            uniqueKeysWithValues: (directSelection?.entries ?? []).map {
                ($0.id, $0.selection)
            }
        )
        var result: [SelectionEntry] = []
        for entry in selection.entries {
            try budget.check()
            let source: TextSelection
            let positions: PositionMap
            if blockIDs.contains(entry.id) {
                source = entry.selection
                positions = totalPositions
            }
            else if let selected = directResults[entry.id] {
                source = selected
                positions = linePositions
            }
            else {
                // 单点输入已归并重叠目标，不能通过总事务再次加入被归并的旧光标。
                continue
            }
            result.append(
                SelectionEntry(
                    id: entry.id,
                    selection: TextSelection(
                        anchor: try positions.checkedMap(source.anchor),
                        head: try positions.checkedMap(source.head),
                        virtualColumn: source.virtualColumn
                    )
                )
            )
        }
        let primary =
            result.contains(where: { $0.id == selection.primaryID })
            ? selection.primaryID : directSelection?.primaryID ?? selection.primaryID
        return try PreparedTransaction(
            snapshot: snapshot,
            edits: merged,
            selectionStateAfter: SelectionState(entries: result, primaryID: primary),
            name: "跨行增加缩进",
            permit: allowed
        )
    }
}
