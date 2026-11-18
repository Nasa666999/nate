import Foundation

private struct SelectionNormalizationGroup {
    var range: ByteRange
    var winner: Int
}

extension SelectionState {
    /// 业务作用：一次编辑只处理每处正文一次，归并选择同时保留主项身份或最早建立项身份及其方向。
    /// 参数说明:
    /// - text: 所有原选择依附的同一正文。
    /// - permit: 验证、排序和归并共用的执行资格。
    /// 返回：文档顺序下的不交叠完整选择，主项持续存在；虚拟位置冲突、取消或超量时原集合保留。
    public func normalized(
        in text: PieceTree,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        _ = try validated(in: text, permit: permit)
        var comparisons = 0
        let ordered = try entries.indices.sorted {
            comparisons += 1
            if comparisons & 255 == 0 {
                try budget.check()
            }
            let a = entries[$0].selection.range, b = entries[$1].selection.range
            if a.lower != b.lower {
                return a.lower < b.lower
            }
            if a.upper != b.upper {
                return a.upper < b.upper
            }
            return $0 < $1
        }
        var groups: [SelectionNormalizationGroup] = []
        for (index, source) in ordered.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            let entry = entries[source], range = entry.selection.range
            if var last = groups.last,
                range.lower < last.range.upper || range == last.range
                    || last.range.isEmpty && range.lower == last.range.lower
            {
                let winner = entries[last.winner]
                // 同字节处的不同虚拟列是不同视觉目标，不能任取一项后把另一项的输入静默丢弃。
                guard
                    !range.isEmpty || !last.range.isEmpty
                        || entry.selection.virtualColumn == winner.selection.virtualColumn
                else {
                    throw NateError.message("同一真实位置包含不同虚拟光标列，未选择任意一份输入目标。")
                }
                last.range = ByteRange(last.range.lower, max(last.range.upper, range.upper))
                if entry.id == primaryID || winner.id != primaryID && source < last.winner {
                    last.winner = source
                }
                groups[groups.count - 1] = last
            }
            else {
                groups.append(SelectionNormalizationGroup(range: range, winner: source))
            }
        }
        var result: [SelectionEntry] = []
        for (index, group) in groups.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            let winner = entries[group.winner]
            let forward = winner.selection.anchor <= winner.selection.head
            result.append(
                SelectionEntry(
                    id: winner.id,
                    selection: TextSelection(
                        anchor: forward ? group.range.lower : group.range.upper,
                        head: forward ? group.range.upper : group.range.lower,
                        virtualColumn: group.range.isEmpty ? winner.selection.virtualColumn : 0
                    )
                )
            )
        }
        try budget.check()
        return try SelectionState(
            entries: result,
            primaryID: primaryID,
            shape: result.count == entries.count ? shape : .stream
        )
    }
}
