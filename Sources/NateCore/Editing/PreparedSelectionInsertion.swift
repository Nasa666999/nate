import Foundation

public struct SelectionInsertionTarget: Sendable {
    public let id: UUID
    public let range: ByteRange
    public let text: String
    public let leadingSpaces: Int
    public let trailingSpaces: Int
    public let virtualColumnAfter: Int

    /// 业务作用：明确每项选择的实际替换、输入与保留空白，Tab 拆分和片段粘贴不提前改写源选择。
    /// 参数说明:
    /// - id: 结果继续使用的稳定选择身份，新建目标须明确提供新身份。
    /// - range: 同一原快照上的实际替换范围。
    /// - text: 该目标真实确认的输入文字。
    /// - leadingSpaces: 输入前保留或补齐的空格数量。
    /// - trailingSpaces: 被拆分 Tab 在输入后保留的空格数量。
    /// - virtualColumnAfter: 空操作后仍保留在真实行尾之外的光标列数。
    /// 返回：尚未校验正文和容量的完整意图，不持有发布权限。
    public init(
        id: UUID,
        range: ByteRange,
        text: String,
        leadingSpaces: Int = 0,
        trailingSpaces: Int = 0,
        virtualColumnAfter: Int = 0
    ) {
        self.id = id
        self.range = range
        self.text = text
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
        self.virtualColumnAfter = virtualColumnAfter
    }
}

public struct PreparedSelectionInsertion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：把完整逐项插入意图构建为一个事务，保留原撤销来源、存活身份和主项。
    /// 参数说明:
    /// - snapshot: 带完整源选择与控制代次的原正文。
    /// - targets: 一至十万项明确且不交叠的实际编辑目标。
    /// - primaryID: 结果主项，省略时继续使用原主项，必须存在于结果中。
    /// - shapeAfter: 已明确准备的结果形态，默认普通流，必须匹配结果身份与全部边缘。
    /// - name: 用户可理解的撤销名称。
    /// - permit: 范围、空白与正文构建共用的执行资格。
    /// 返回：全部容量和边界通过后生成完整事务；失败不发布部分空白或临时选择。
    public init(
        snapshot: DocumentSnapshot,
        targets: [SelectionInsertionTarget],
        primaryID: UUID? = nil,
        shapeAfter: SelectionShape = .stream,
        name: String = "输入",
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            !targets.isEmpty, targets.count <= 100_000,
            Set(targets.map(\.id)).count == targets.count
        else {
            throw NateError.message("逐项输入需要完整源选择和一至十万个独立目标。")
        }
        _ = try original.validated(in: snapshot.text, permit: permit)
        // 明确结果坐标不能替旧矩形重新授予当前列权限，原正文变化后仍须用户重选。
        if case .rectangle(let rectangle) = original.shape, rectangle.needsRevalidation {
            throw NateError.message("矩形正文已经改变，请重新选择边缘后再输入。")
        }
        let primary = primaryID ?? original.primaryID
        guard
            targets.contains(where: {
                $0.id == primary
            })
        else {
            throw NateError.message("逐项输入缺少明确的结果主选区。")
        }
        var comparisons = 0
        let ordered = try targets.sorted {
            comparisons += 1
            if comparisons & 255 == 0 {
                try budget.check()
            }
            return $0.range.lower == $1.range.lower
                ? $0.range.upper < $1.range.upper : $0.range.lower < $1.range.lower
        }
        var previous: ByteRange?
        var output = 0, removed = 0
        for target in ordered {
            try budget.check()
            guard target.range.lower >= 0, target.range.upper >= target.range.lower,
                snapshot.text.isBoundary(target.range.lower), snapshot.text.isBoundary(target.range.upper),
                (0...1_000_000).contains(target.leadingSpaces),
                (0...1_000_000).contains(target.trailingSpaces),
                (0...1_000_000).contains(target.virtualColumnAfter),
                target.text.utf8.count <= 64 * 1024 * 1024
            else {
                throw NateError.invalidRange
            }
            guard
                target.virtualColumnAfter == 0
                    || target.range.isEmpty && target.text.isEmpty && target.leadingSpaces == 0
                        && target.trailingSpaces == 0
            else {
                throw NateError.message("保留虚拟光标只适用于没有实际插入和删除的目标。")
            }
            if let previous {
                guard previous.upper <= target.range.lower, !(previous.isEmpty && previous == target.range)
                else {
                    throw NateError.overlappingEdits
                }
            }
            for point in [target.range.lower, target.range.upper] {
                guard !(snapshot.text.byte(at: point - 1) == 13 && snapshot.text.byte(at: point) == 10) else {
                    throw NateError.message("逐项输入不能切开 CRLF。")
                }
            }
            let size = target.text.utf8.count + target.leadingSpaces + target.trailingSpaces
            guard size <= 256 * 1024 * 1024 - output else {
                throw NateError.message("逐项输入与空白超过 256 MiB，未分配部分填充。")
            }
            output += size
            removed += target.range.count
            previous = target.range
        }
        // 完整最终规模先于空白与新正文分配，不能在后面的目标超量后留下前面目标的副作用。
        guard snapshot.text.byteCount - removed <= 1024 * 1024 * 1024 - output else {
            throw NateError.message("逐项输入后的正文超过 1 GiB。")
        }
        var edits: [TextEdit] = []
        var results: [UUID: SelectionEntry] = [:]
        var delta = 0
        for target in ordered {
            try budget.check()
            let value =
                String(repeating: " ", count: target.leadingSpaces) + target.text
                + String(repeating: " ", count: target.trailingSpaces)
            let caret = target.range.lower + delta + target.leadingSpaces + target.text.utf8.count
            edits.append(TextEdit(target.range, value))
            results[target.id] = SelectionEntry(
                id: target.id,
                selection: TextSelection(anchor: caret, head: caret, virtualColumn: target.virtualColumnAfter)
            )
            delta += value.utf8.count - target.range.count
        }
        var entries = original.entries.compactMap {
            results.removeValue(forKey: $0.id)
        }
        entries += targets.compactMap {
            results.removeValue(forKey: $0.id)
        }
        let after = try SelectionState(entries: entries, primaryID: primary, shape: shapeAfter)
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: after,
            name: name,
            permit: permit
        )
        try budget.check()
    }
}
