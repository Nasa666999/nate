import Foundation

extension SelectionState {
    /// 业务作用：将选择几何与实际正文完整复验，虚拟起点不能借普通范围进入行内或跨行矩形。
    /// 参数说明:
    /// - text: 当前不可变正文。
    /// - permit: 复验仍属于当前动作，为假时整体停止。
    /// 返回：全部选择和矩形行合法时保留同一完整状态；取消、五秒超时或任一范围无效时失败。
    public func validated(
        in text: PieceTree,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        try validated(in: text, permit: permit, checkingCancellation: true)
    }

    /// 业务作用：正文已串行发布后的视图同步必须完成其边界校验，不能被原后台动作的取消标志留下旧坐标。
    /// 参数说明:
    /// - text: 当前实际正文。
    /// - permit: 复验的完整执行资格。
    /// - checkingCancellation: 后台准备是否仍须响应任务取消。
    /// 返回：完整合法状态；范围、容量或截止无效时失败。
    func validated(
        in text: PieceTree,
        permit: @Sendable () -> Bool = {
            true
        },
        checkingCancellation: Bool
    ) throws -> SelectionState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let rectangular: Bool
        if case .rectangle(let rectangle) = shape {
            rectangular = !rectangle.needsRevalidation
        }
        else {
            rectangular = false
        }
        var rows: Set<Int> = []
        let projections: [UUID: RectangleEditProjection]
        if case .rectangle(let rectangle) = shape {
            projections = Dictionary(
                uniqueKeysWithValues: rectangle.edges.compactMap {
                    edge in
                    edge.projection.map {
                        (edge.selectionID, $0)
                    }
                }
            )
        }
        else {
            projections = [:]
        }
        let entirelyASCII = text.byteCount == text.utf16Count
        for (index, entry) in entries.enumerated() {
            if index & 255 == 0 {
                if checkingCancellation {
                    try Task.checkCancellation()
                }
                guard permit() else {
                    throw CancellationError()
                }
                guard ContinuousClock.now < deadline else {
                    throw NateError.message("选择边界复验超过五秒，原完整状态保留。")
                }
            }
            let value = entry.selection
            let range = value.range
            guard range.lower >= 0, range.upper <= text.byteCount,
                entirelyASCII || text.isBoundary(value.anchor) && text.isBoundary(value.head)
            else {
                throw NateError.invalidRange
            }
            guard rectangular || value.virtualColumn != 0 else {
                continue
            }
            let body = text.physicalLineBody(containing: range.lower)
            // 虚拟空白只能定位真实行尾之外，不能与已有行内正文重叠后再次补空格。
            guard value.virtualColumn == 0 || range.isEmpty && value.head == body.upper else {
                throw NateError.message("虚拟光标必须位于真实行尾。")
            }
            if rectangular {
                if let projection = projections[entry.id] {
                    _ = try projection.validated(
                        for: value,
                        in: text,
                        body: body,
                        checkingCancellation: checkingCancellation
                    )
                }
                // 完整矩形每行只能有一个目标，跨行范围或重复行会破坏块粘贴和行键权限。
                guard range.lower >= body.lower, range.upper <= body.upper,
                    rows.insert(body.lower).inserted
                else {
                    throw NateError.message("矩形选择包含跨行范围或重复逻辑行。")
                }
                // ASCII 内唯一的多字节字形是 CRLF，真实正文范围已经排除了该行尾和行尾内部。
                if !entirelyASCII {
                    var graphemes = try GraphemeNavigation(
                        text: text,
                        checkingCancellation: checkingCancellation
                    )
                    guard ContinuousClock.now < deadline else {
                        throw NateError.message("矩形边缘复验超过五秒，原完整状态保留。")
                    }
                    guard try graphemes.isBoundary(at: value.anchor) && graphemes.isBoundary(at: value.head)
                    else {
                        throw NateError.message("矩形边缘位于一个完整字形簇内部，未切开列选择。")
                    }
                }
            }
        }
        if case .rectangle(let rectangle) = shape, !rectangle.needsRevalidation,
            let anchorID = rectangle.anchorID, let headID = rectangle.headID
        {
            // 纵向端点必须覆盖全部现存目标，不能用一个内部主项伪装成完整矩形的活动边缘。
            guard
                let anchor = entries.first(where: {
                    $0.id == anchorID
                }),
                let head = entries.first(where: {
                    $0.id == headID
                }),
                let first = rows.min(), let last = rows.max()
            else {
                throw NateError.invalidRange
            }
            let a = text.physicalLineBody(containing: anchor.selection.range.lower).lower
            let b = text.physicalLineBody(containing: head.selection.range.lower).lower
            guard min(a, b) == first, max(a, b) == last else {
                throw NateError.message("矩形纵向端点未覆盖全部选择行，原状态保持不变。")
            }
        }
        if checkingCancellation {
            try Task.checkCancellation()
        }
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("选择边界复验超过五秒，原完整状态保留。")
        }
        return self
    }

    /// 业务作用：显式切换主选区，不改变建立顺序、稳定身份或任一几何。
    /// 参数说明:
    /// - id: 必须仍存在于本集合中的选区身份。
    /// 返回：主项明确更新的完整集合；陌生或已合并身份时失败。
    public func selectingPrimary(_ id: UUID) throws -> SelectionState {
        if id == primaryID {
            return self
        }
        return try SelectionState(entries: entries, primaryID: id, shape: shape)
    }

    /// 业务作用：为同一组稳定行身份明确绑定形态，不能把缺失边缘或另一组身份当作当前矩形。
    /// 参数说明:
    /// - shape: 用户交互明确建立的完整选择形态。
    /// 返回：几何和身份保持原值的新形态；不完整矩形时失败。
    public func usingShape(_ shape: SelectionShape) throws -> SelectionState {
        try SelectionState(entries: entries, primaryID: primaryID, shape: shape)
    }
}
