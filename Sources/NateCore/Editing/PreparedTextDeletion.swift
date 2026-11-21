import Foundation

public struct PreparedTextDeletion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：普通选择的删除按稳定身份准备完整结果，光标字形和缩进目标共用一次原子提交。
    /// 参数说明:
    /// - snapshot: 含完整源选择和控制代次的固定正文。
    /// - forward: 空光标删除右侧字形，为假时退格；非空选区按明确原字节范围删除。
    /// - settings: 当前语言合法的 Tab 宽度。
    /// - backspaceUnindents: 普通前导空白是否退到上一停靠位，虚拟列仍按一列移动。
    /// - permit: 全部验证、目标与正文构建共享的继续资格。
    /// 返回：保留原建立顺序、主项及完整撤销来源的事务；任何目标缺少证据或超限时整体失败。
    public init(
        snapshot: DocumentSnapshot,
        forward: Bool,
        settings: TabSettings = TabSettings(),
        backspaceUnindents: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        let sharedPermit: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        // 普通删除不具备原生矩形边缘证据，缺少完整来源或使用列形状时不能猜测实际字节。
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            case .stream = original.shape
        else {
            throw NateError.message("普通删除需要完整流式选择身份，矩形删除须先证明原生边缘。")
        }
        let targets = try original.normalized(in: snapshot.text, permit: sharedPermit)
        var navigation: GraphemeNavigation?
        var indentation: IndentationBackspaceReader?
        if !forward && backspaceUnindents {
            indentation = try IndentationBackspaceReader(
                text: snapshot.text,
                tabWidth: settings.width,
                deadline: budget.deadline,
                permit: sharedPermit
            )
        }
        var ranges: [ByteRange] = []
        var resultByID: [UUID: TextSelection] = [:]
        for entry in targets.entries {
            try budget.check()
            let selection = entry.selection
            if selection.range.isEmpty && selection.virtualColumn > 0 {
                resultByID[entry.id] = TextSelection(
                    anchor: selection.head,
                    head: selection.head,
                    virtualColumn: max(0, selection.virtualColumn - (forward ? 0 : 1))
                )
                continue
            }
            let range: ByteRange
            if !selection.range.isEmpty {
                range = selection.range
            }
            else if let stepped = try indentation?.range(before: selection.head) {
                range = stepped
            }
            else {
                // 字形读取预算从首个实际字形目标开始，原缩进扫描不能让尚未使用的导航证据提前过期。
                if navigation == nil {
                    navigation = try GraphemeNavigation(text: snapshot.text)
                }
                guard let value = try navigation?.range(at: selection.head, forward: forward) else {
                    throw NateError.message("当前删除没有完整字形证据。")
                }
                range = value
            }
            if !range.isEmpty {
                ranges.append(range)
            }
            resultByID[entry.id] = TextSelection(
                anchor: range.lower,
                head: range.lower
            )
        }
        var comparisons = 0
        let sorted = try ranges.sorted {
            comparisons += 1
            if comparisons & 255 == 0 {
                try budget.check()
            }
            return $0.lower < $1.lower
        }
        var merged: [ByteRange] = []
        for range in sorted {
            try budget.check()
            if let prior = merged.last, range.lower <= prior.upper {
                merged[merged.count - 1] = ByteRange(prior.lower, max(prior.upper, range.upper))
            }
            else {
                merged.append(range)
            }
        }
        let edits = merged.map {
            TextEdit($0, "")
        }
        let positions = try PositionMap(edits: edits)
        var entries: [SelectionEntry] = []
        // 文档顺序只服务区间归并，发布仍按原建立顺序取回身份，不能以结果几何重新分配主项。
        for entry in original.entries {
            try budget.check()
            if let result = resultByID[entry.id] {
                entries.append(
                    SelectionEntry(
                        id: entry.id,
                        selection: TextSelection(
                            anchor: positions.map(result.anchor),
                            head: positions.map(result.head),
                            virtualColumn: result.virtualColumn
                        )
                    )
                )
            }
        }
        let after = try SelectionState(
            entries: entries,
            primaryID: targets.primaryID
        )
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: after,
            name: forward ? "向后删除" : "退格",
            permit: sharedPermit
        )
    }
}
