import AppKit
import NateCore

extension EditorView {
    /// 业务作用：仅向列操作提供当前正文和选择身份共同证明的真实矩形，普通多选不被推测为列键。
    /// 参数说明: 无。
    /// 返回：原矩形仍属于当前修订和选择时的完整目标，否则为空。
    public var rectangularSelections: [TextSelection]? {
        guard selectionStateRevision == document.revision, let viewSelectionState,
            case .rectangle = viewSelectionState.shape
        else {
            return nil
        }
        return viewSelections
    }

    /// 业务作用：区分真实零宽矩形与正宽但未覆盖字形的空键，避免后者扩大为行尾后缀。
    /// 参数说明: 无。
    /// 返回：当前矩形的真实零宽状态，形状证据过期或普通选择时为空。
    public var rectangleUsesSuffix: Bool? {
        guard rectangularSelections != nil, let viewSelectionState,
            case .rectangle(let rectangle) = viewSelectionState.shape
        else {
            return nil
        }
        return rectangle.zeroWidth
    }

    /// 业务作用：完整验证并建立每行一个实际列目标，短行虚拟位置不写入正文。
    /// 参数说明:
    /// - selections: 按交互顺序的矩形行内目标，最多十万行。
    /// - zeroWidth: 可选的实际像素零宽形状；为空时按全部实际空范围判断。
    /// - anchorX: 可选的固定正文视觉横坐标，不含边栏。
    /// - headX: 可选的活动正文视觉横坐标，不含边栏。
    /// - trailingColumns: 每行被选中的额外虚拟空白，省略时保留仍对应原身份的边缘。
    /// - primaryRow: 可选的明确活动逻辑行，用于拖选末端成为主项。
    /// 返回：全部目标有效时更新选择和形状身份；跨行、重复行、候选或保护期间保留原选择。
    @discardableResult
    public func setRectangularSelections(
        _ selections: [TextSelection],
        zeroWidth: Bool? = nil,
        anchorX: Double? = nil,
        headX: Double? = nil,
        trailingColumns: [Int]? = nil,
        primaryRow: Int? = nil
    ) -> Bool {
        // 候选与保护仍持有当前输入或元数据，不能借列形状切换改变这份状态。
        guard composition == nil, !document.isEditingSuspended,
            !selections.isEmpty, selections.count <= 100_000,
            trailingColumns.map({
                $0.count == selections.count
            }) ?? true
        else {
            return false
        }
        let empty = selections.allSatisfy {
            $0.range.isEmpty
        }
        let suffix = zeroWidth ?? empty
        guard !suffix || empty else {
            return false
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var oldRows: [Int: SelectionEntry] = [:]
            var oldRectangle: RectangleSelectionShape?
            if selectionStateRevision == document.revision, let state = viewSelectionState {
                for entry in state.entries where document.text.isBoundary(entry.selection.range.lower) {
                    let row = document.text.lineNumber(at: entry.selection.range.lower)
                    if oldRows[row] == nil || entry.id == state.primaryID {
                        oldRows[row] = entry
                    }
                }
                if case .rectangle(let rectangle) = state.shape {
                    oldRectangle = rectangle
                }
            }
            var rows: Set<Int> = []
            var entries: [SelectionEntry] = []
            var primary: UUID?
            for selection in selections {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw NateError.message("矩形选择准备超过五秒，原选择保留。")
                }
                guard document.text.isBoundary(selection.anchor), document.text.isBoundary(selection.head),
                    (0...1_000_000).contains(selection.virtualColumn)
                else {
                    throw NateError.invalidRange
                }
                let row = document.text.lineNumber(at: selection.range.lower)
                let body = document.text.lineRange(row, includeEnding: false)
                guard selection.range.upper <= body.upper, rows.insert(row).inserted,
                    selection.virtualColumn == 0 || selection.range.isEmpty && selection.head == body.upper
                else {
                    throw NateError.message("矩形选择要求每行一个完整目标，虚拟光标必须位于行尾。")
                }
                var navigation = try GraphemeNavigation(text: document.text)
                guard
                    try navigation.isBoundary(at: selection.anchor)
                        && navigation.isBoundary(at: selection.head)
                else {
                    throw NateError.message("矩形边缘必须位于完整字形簇之间，原选择保留。")
                }
                let entry = SelectionEntry(id: oldRows[row]?.id ?? UUID(), selection: selection)
                entries.append(entry)
                if row == primaryRow || primaryRow == nil && entry.id == viewSelectionState?.primaryID {
                    primary = entry.id
                }
            }
            guard let first = entries.first, primaryRow == nil || primary != nil else {
                throw NateError.invalidRange
            }
            let prior = Dictionary(
                uniqueKeysWithValues: (oldRectangle?.edges ?? []).map {
                    ($0.selectionID, $0)
                }
            )
            var edges: [SelectionVirtualEdge] = []
            for (index, entry) in entries.enumerated() {
                let trailing = suffix ? 0 : trailingColumns?[index] ?? prior[entry.id]?.trailingColumns ?? 0
                edges.append(
                    try SelectionVirtualEdge(
                        selectionID: entry.id,
                        leadingColumns: entry.selection.virtualColumn,
                        trailingColumns: trailing
                    )
                )
            }
            let fixed =
                anchorX ?? oldRectangle?.anchorX
                ?? rectangleCaretX(at: first.selection.anchor, virtual: first.selection.virtualColumn)
            let active =
                headX ?? oldRectangle?.headX
                ?? rectangleCaretX(at: first.selection.head, virtual: first.selection.virtualColumn)
            let shape = try RectangleSelectionShape(
                anchorX: fixed,
                headX: active,
                zeroWidth: suffix,
                edges: edges
            )
            let state = try SelectionState(
                entries: entries,
                primaryID: primary ?? first.id,
                shape: .rectangle(shape)
            )
            // 完整形态和全部行边缘准备完毕后才发布，任何失败不能留下半份矩形或不一致身份。
            try setSelectionState(state)
            selectionGeneration = UUID()
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：普通移动或重新点击离开列选择，即使光标撞到边界也撤销旧形状与后台计划。
    /// 参数说明: 无。
    /// 返回：正文和几何选择保持原值，存在矩形时推进选择身份。
    func clearRectangularSelection() {
        if let viewSelectionState, case .rectangle = viewSelectionState.shape {
            do {
                try setSelectionState(viewSelectionState.usingShape(.stream))
            }
            catch {
                onStatus?(error.localizedDescription)
            }
        }
    }

    /// 业务作用：程序化矩形缺少原视觉横坐标时只取首行真实原生光标，不把 UTF-8 字节长度当作列宽。
    /// 参数说明:
    /// - offset: 当前正文的合法端点。
    /// - virtual: 行尾之后尚未写入的空白列。
    /// 返回：相对正文左边缘的真实像素位置，虚拟部分使用当前字体的空格列宽。
    private func rectangleCaretX(at offset: Int, virtual: Int) -> Double {
        let row = document.text.lineNumber(at: offset)
        let layout = layoutLine(row)
        let units = document.text.utf16Offset(byte: offset) ?? layout.originUTF16
        return Double(layout.caret(at: units - layout.originUTF16).minX)
            + Double(virtual) * Double(max(1, font.maximumAdvancement.width))
    }
}
