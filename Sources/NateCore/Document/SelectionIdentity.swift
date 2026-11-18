import Foundation

struct SelectionPreparationBudget {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let permit: @Sendable () -> Bool
    let checkingCancellation: Bool

    /// 业务作用：后台准备允许取消，已经发生的串行几何赋值则必须完整登记其新身份。
    /// 参数说明:
    /// - permit: 本轮完整准备的执行资格。
    /// - checkingCancellation: 是否遵循当前任务的取消状态。
    /// 返回：仍受五秒截止约束的共同预算。
    init(permit: @escaping @Sendable () -> Bool, checkingCancellation: Bool = true) {
        self.permit = permit
        self.checkingCancellation = checkingCancellation
    }

    /// 业务作用：身份匹配、归并和位置复验共享预算，取消不能返回一部分已重建的选择。
    /// 参数说明: 无。
    /// 返回：当前仍可执行时继续，取消、失权或五秒超时整体失败。
    func check() throws {
        if checkingCancellation {
            try Task.checkCancellation()
        }
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("完整选择准备超过五秒，原选择状态保留。")
        }
    }
}

extension SelectionState {
    /// 业务作用：几何更新优先保留完全匹配的原身份，其余同序号移动继续使用尚未占用的旧身份。
    /// 参数说明:
    /// - selections: 完整的新几何，按调用者建立顺序保留。
    /// - primaryIndex: 可选的明确主项位置，不提供时保留仍存在的原主身份。
    /// - permit: 身份准备仍属于当前动作，为假时整体停止。
    /// 返回：每个旧身份最多使用一次，新增项分配新身份；几何改变时切换普通形态，完整矩形须另行明确绑定。
    public func replacingGeometries(
        _ selections: [TextSelection],
        primaryIndex: Int? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        try replacingGeometries(
            selections,
            primaryIndex: primaryIndex,
            permit: permit,
            checkingCancellation: true
        )
    }

    /// 业务作用：兼容几何赋值已经完成后同步登记身份，任务取消不能使已接受的几何与身份分离。
    /// 参数说明:
    /// - selections: 串行入口刚接受的完整几何。
    /// 返回：完整身份匹配；无效几何或容量不足时失败，由所属文档关闭后续事务门禁。
    public func acceptingGeometries(_ selections: [TextSelection]) throws -> SelectionState {
        try replacingGeometries(
            selections,
            primaryIndex: nil,
            permit: {
                true
            },
            checkingCancellation: false
        )
    }

    /// 业务作用：普通赋值和可取消后台计划共享同一身份匹配规则，不引入相互冲突的主项语义。
    /// 参数说明:
    /// - selections: 新的完整几何。
    /// - primaryIndex: 可选的明确主项。
    /// - permit: 完整准备的执行资格。
    /// - checkingCancellation: 后台计划是否仍服从任务取消。
    /// 返回：按相同规则完整匹配的选择集合，任一步失败不提供部分身份。
    private func replacingGeometries(
        _ selections: [TextSelection],
        primaryIndex: Int?,
        permit: @escaping @Sendable () -> Bool,
        checkingCancellation: Bool
    ) throws -> SelectionState {
        let budget = SelectionPreparationBudget(permit: permit, checkingCancellation: checkingCancellation)
        try budget.check()
        guard !selections.isEmpty, selections.count <= 100_000,
            primaryIndex.map({
                selections.indices.contains($0)
            }) ?? true
        else {
            throw NateError.invalidRange
        }
        let unchanged = selections == self.selections
        if unchanged, primaryIndex == nil {
            return self
        }
        var first: [TextSelection: Int] = [:]
        var next = [Int](repeating: -1, count: entries.count)
        for index in entries.indices.reversed() {
            if index & 255 == 0 {
                try budget.check()
            }
            let value = entries[index].selection
            next[index] = first[value] ?? -1
            first[value] = index
        }
        var matched = [Int?](repeating: nil, count: selections.count)
        var used = [Bool](repeating: false, count: entries.count)
        for (index, value) in selections.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            if let old = first[value] {
                matched[index] = old
                used[old] = true
                first[value] = next[old] < 0 ? nil : next[old]
            }
        }
        let unchangedMembers =
            selections.count == entries.count
            && matched.allSatisfy {
                $0 != nil
            }
        if selections.count == 1, matched[0] == nil,
            let primary = entries.firstIndex(where: {
                $0.id == primaryID
            })
        {
            matched[0] = primary
            used[primary] = true
        }
        var result: [SelectionEntry] = []
        for (index, value) in selections.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            if matched[index] == nil, index < entries.count, !used[index] {
                matched[index] = index
                used[index] = true
            }
            let id =
                matched[index].map {
                    entries[$0].id
                } ?? UUID()
            result.append(SelectionEntry(id: id, selection: value))
        }
        let primary: UUID
        if let primaryIndex {
            primary = result[primaryIndex].id
        }
        else {
            primary =
                result.first(where: {
                    $0.id == primaryID
                })?.id ?? result[0].id
        }
        try budget.check()
        return try SelectionState(
            entries: result,
            primaryID: primary,
            shape: unchanged || unchangedMembers ? shape : .stream
        )
    }

    /// 业务作用：正文位置映射保持每项稳定身份，普通编辑后的矩形像素意图由调用者明确决定是否继续保留。
    /// 参数说明:
    /// - positions: 原正文到结果正文的完整位置图。
    /// - text: 即将显示的结果正文。
    /// - preservingRectangle: 明确保留矩形形态，适用于已验证的完整行移动。
    /// - permit: 完整映射和验证共用的执行资格。
    /// 返回：身份、主项和方向连续的完整选择；越界、无效矩形或取消时不返回部分选择。
    public func mapped(
        through positions: PositionMap,
        in text: PieceTree,
        preservingRectangle: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        try mapped(
            through: [positions],
            in: text,
            preservingRectangle: preservingRectangle,
            permit: permit
        )
    }

    /// 业务作用：克隆跨过多个修订时只在最终正文复验坐标，中间位置不能拿最终文本提前校验。
    /// 参数说明:
    /// - positions: 按真实提交顺序排列的完整位置图。
    /// - text: 位置链末端的实际正文。
    /// - preservingRectangle: 调用方确认整条链保持了原行像素意图。
    /// - permit: 完整位置链映射的执行资格。
    /// 返回：保持原身份和主项的最终完整状态；任一位置溢出、链末边界无效或取消时整体失败。
    public func mapped(
        through positions: [PositionMap],
        in text: PieceTree,
        preservingRectangle: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        try mapped(
            through: positions,
            in: text,
            preservingRectangle: preservingRectangle,
            checkingCancellation: true,
            permit: permit
        )
    }

    /// 业务作用：可取消后台计划与已发布正文的串行视图同步共享同一完整位置链规则。
    /// 参数说明:
    /// - positions: 真实连续位置链。
    /// - text: 链末正文。
    /// - preservingRectangle: 是否明确保留原行矩形形态。
    /// - checkingCancellation: 是否仍响应原任务的取消状态。
    /// - permit: 当前完整同步的执行资格。
    /// 返回：全部原身份映射后的完整状态；失败不返回部分坐标。
    func mapped(
        through positions: [PositionMap],
        in text: PieceTree,
        preservingRectangle: Bool,
        checkingCancellation: Bool,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        let budget = SelectionPreparationBudget(permit: permit, checkingCancellation: checkingCancellation)
        guard positions.count <= 256 else {
            throw NateError.message("选择位置链超过 256 个事务，未套用不完整修订。")
        }
        var result: [SelectionEntry] = []
        var virtual: [UUID: Int] = [:]
        var steps = 0
        for (index, entry) in entries.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            let old = entry.selection
            var anchor = old.anchor, head = old.head
            for positions in positions {
                if steps & 255 == 0 {
                    try budget.check()
                }
                anchor = try positions.checkedMap(anchor)
                head = try positions.checkedMap(head)
                steps += 1
            }
            guard text.isBoundary(anchor), text.isBoundary(head) else {
                throw NateError.invalidRange
            }
            let body = text.lineRange(text.lineNumber(at: head), includeEnding: false)
            let column = anchor == head && head == body.upper ? old.virtualColumn : 0
            result.append(
                SelectionEntry(
                    id: entry.id,
                    selection: TextSelection(
                        anchor: anchor,
                        head: head,
                        virtualColumn: column
                    )
                )
            )
            virtual[entry.id] = column
        }
        let mappedShape: SelectionShape
        if preservingRectangle, case .rectangle(let rectangle) = shape {
            var anchorID = rectangle.anchorID
            var headID = rectangle.headID
            if let anchor = entries.first(where: {
                $0.id == anchorID
            }),
                let head = entries.first(where: {
                    $0.id == headID
                }),
                let low = result.min(by: {
                    $0.selection.range.lower < $1.selection.range.lower
                }),
                let high = result.max(by: {
                    $0.selection.range.lower < $1.selection.range.lower
                })
            {
                // 行置换移动各选择身份，但矩形纵向方向仍覆盖完整物理跨度，内部行不能成为新的外边缘。
                let forward = anchor.selection.range.lower <= head.selection.range.lower
                anchorID = forward ? low.id : high.id
                headID = forward ? high.id : low.id
            }
            let edges = try rectangle.edges.map {
                try SelectionVirtualEdge(
                    selectionID: $0.selectionID,
                    leadingColumns: virtual[$0.selectionID] ?? 0,
                    trailingColumns: $0.trailingColumns
                )
            }
            mappedShape = .rectangle(
                try RectangleSelectionShape(
                    anchorX: rectangle.anchorX,
                    headX: rectangle.headX,
                    zeroWidth: rectangle.zeroWidth,
                    edges: edges,
                    anchorID: anchorID,
                    headID: headID
                )
            )
        }
        else {
            mappedShape = .stream
        }
        let state = try SelectionState(entries: result, primaryID: primaryID, shape: mappedShape)
        _ = try state.validated(
            in: text,
            permit: {
                permit() && ContinuousClock.now < budget.deadline
            },
            checkingCancellation: checkingCancellation
        )
        try budget.check()
        return state
    }
}
