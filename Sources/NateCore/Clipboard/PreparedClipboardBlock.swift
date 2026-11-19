import Foundation

public struct PreparedClipboardBlock: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：矩形粘贴按真实行数完成删除、Tab 保留和末尾扩展，全部修改只发布一个事务。
    /// 参数说明:
    /// - snapshot: 带完整原选择与控制代次的源正文。
    /// - content: 已完成明确换行适配的载荷。
    /// - layout: 同一来源和视图下准备的全部真实行边缘。
    /// - deadline: 解码、布局和正文构建共用的截止。
    /// - permit: 本轮仍持有准备资格。
    /// 返回：光标回到块起点、撤销恢复原完整选择的事务；缺行、重复行、超量或取消时完整失败。
    public init(
        snapshot: DocumentSnapshot,
        content: ClipboardPasteContent,
        layout: ClipboardBlockLayout,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            !layout.targets.isEmpty, layout.targets.count <= ClipboardLimits.fragments,
            (0..<ClipboardLimits.fragments).contains(layout.additionalRows),
            (0...1_000_000).contains(layout.newRowPadding)
        else {
            throw NateError.message("矩形粘贴缺少完整来源或有效行布局。")
        }
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        _ = try original.validated(in: snapshot.text, permit: allowed)
        // 旧正文上的块边缘不能直接沿新正文展开，避免把保留列当成新的粘贴目标。
        if case .rectangle(let rectangle) = original.shape, rectangle.needsRevalidation {
            throw NateError.message("矩形正文已经改变，请重新选择边缘后再粘贴。")
        }
        let rectanglePayload: Bool
        if case .rectangle = content.payload.shape {
            rectanglePayload = true
        }
        else {
            rectanglePayload = false
        }
        var base = snapshot.text
        let selectedRows: [Int]
        let anchor: Int
        switch original.shape {
        case .stream:
            let selected = try original.normalized(in: snapshot.text, permit: allowed)
            guard rectanglePayload, selected.entries.count == 1 else {
                throw NateError.message("普通多目标粘贴不能被猜成多个矩形块。")
            }
            let range = selected.primary.selection.range
            guard layout.baseRemoval == (range.isEmpty ? nil : range) else {
                throw NateError.message("块粘贴的临时移除范围与原普通选择不一致。")
            }
            if let removal = layout.baseRemoval {
                var navigation = try GraphemeNavigation(text: snapshot.text)
                guard try navigation.isBoundary(at: removal.lower),
                    try navigation.isBoundary(at: removal.upper)
                else {
                    throw NateError.message("块粘贴不能在移除原选择时切开完整字形或 CRLF。")
                }
                base = try base.replacing(removal, with: "")
            }
            anchor = range.lower
            var navigation = try GraphemeNavigation(text: base)
            guard try navigation.isBoundary(at: anchor) else {
                throw NateError.message("移除选择后的块起点位于组合字形内部，未切开相邻正文。")
            }
            selectedRows = [base.lineNumber(at: anchor)]
        case .rectangle:
            guard layout.baseRemoval == nil else {
                throw NateError.message("矩形目标必须按行替换，不能先移除跨行正文。")
            }
            selectedRows = original.entries.map {
                base.lineNumber(at: $0.selection.range.lower)
            }.sorted()
            anchor =
                original.entries.map(\.selection.range.lower).min() ?? original.primary.selection.range.lower
        }
        let rowCount =
            rectanglePayload ? max(selectedRows.count, content.documentValues.count) : selectedRows.count
        guard rowCount <= ClipboardLimits.fragments,
            layout.targets.count + layout.additionalRows == rowCount
        else {
            throw NateError.message("块粘贴必须恰好覆盖全部选中行和真实剪贴板行。")
        }
        let paired = rectanglePayload || content.documentValues.count == selectedRows.count
        guard let lastSelectedRow = selectedRows.last else {
            throw NateError.message("块粘贴没有真实来源行，未创建部分布局。")
        }
        var output = 0, removed = layout.baseRemoval?.count ?? 0
        var previous: ByteRange?
        for index in 0..<rowCount {
            try budget.check()
            let value = Self.value(at: index, content: content, paired: paired)
            if index >= layout.targets.count {
                let row = lastSelectedRow + index - selectedRows.count + 1
                guard row == base.lineCount + index - layout.targets.count else {
                    throw NateError.message("文档末尾扩展不能跳过或重复真实行。")
                }
                let size =
                    snapshot.format.lineEnding.text.utf8.count + value.utf8.count
                    + (value.isEmpty ? 0 : layout.newRowPadding)
                try Self.add(size, to: &output)
                continue
            }
            let target = layout.targets[index]
            let row =
                index < selectedRows.count
                ? selectedRows[index] : lastSelectedRow + index - selectedRows.count + 1
            guard row < base.lineCount else {
                throw NateError.message("尚不存在的行不能提供原生字节范围。")
            }
            let body = base.lineRange(row, includeEnding: false)
            guard target.range.lower >= body.lower, target.range.upper >= target.range.lower,
                target.range.upper <= body.upper,
                (0...1_000_000).contains(target.leadingSpaces),
                (0...1_000_000).contains(target.trailingSpaces),
                (0...1_000_000).contains(target.virtualColumn),
                target.virtualColumn == 0
                    || target.range.isEmpty && target.range.lower == body.upper
                        && value.isEmpty && target.leadingSpaces == 0 && target.trailingSpaces == 0
            else {
                throw NateError.invalidRange
            }
            var navigation = try GraphemeNavigation(text: base)
            guard try navigation.isBoundary(at: target.range.lower),
                try navigation.isBoundary(at: target.range.upper),
                previous.map({
                    $0.upper < target.range.lower
                }) ?? true
            else {
                throw NateError.message("块目标必须位于各自真实行的完整字形边缘。")
            }
            if index == 0, case .stream = original.shape {
                // 同点只能替换起点处的 Tab；原生横坐标近似不能把普通选择之前的正文纳入删除。
                guard
                    target.range.lower == anchor
                        || base.byte(at: target.range.lower) == 9
                            && target.range.count == 1 && target.range.lower <= anchor
                            && anchor <= target.range.upper
                else {
                    throw NateError.message("块粘贴的首目标偏离原普通选择起点。")
                }
            }
            removed += target.range.count
            try Self.add(value.utf8.count + target.leadingSpaces + target.trailingSpaces, to: &output)
            previous = target.range
        }
        guard snapshot.text.byteCount - removed <= 1024 * 1024 * 1024 - output else {
            throw NateError.message("块粘贴后的正文超过 1 GiB。")
        }
        // 所有行数、范围和填充容量先通过，再分配实际字符串；失败没有半块正文或空白。
        var baseEdits: [TextEdit] = []
        for (index, target) in layout.targets.enumerated() {
            try budget.check()
            let text =
                String(repeating: " ", count: target.leadingSpaces)
                + Self.value(at: index, content: content, paired: paired)
                + String(repeating: " ", count: target.trailingSpaces)
            baseEdits.append(TextEdit(target.range, text))
        }
        if layout.additionalRows > 0 {
            var append = ""
            for index in layout.targets.count..<rowCount {
                try budget.check()
                let value = Self.value(at: index, content: content, paired: paired)
                append += snapshot.format.lineEnding.text
                if !value.isEmpty {
                    append += String(repeating: " ", count: layout.newRowPadding) + value
                }
            }
            if baseEdits.last?.range == ByteRange(base.byteCount, base.byteCount) {
                baseEdits[baseEdits.count - 1].text += append
            }
            else {
                baseEdits.append(TextEdit(ByteRange(base.byteCount, base.byteCount), append))
            }
        }
        let first = layout.targets[0]
        let position = first.range.lower + first.leadingSpaces
        let entry = SelectionEntry(
            id: original.primaryID,
            selection: TextSelection(anchor: position, head: position, virtualColumn: first.virtualColumn)
        )
        let shape: SelectionShape
        if let x = layout.originTabX {
            guard first.range.isEmpty, first.leadingSpaces == 0, first.trailingSpaces == 0,
                first.virtualColumn == 0, Self.value(at: 0, content: content, paired: paired).isEmpty,
                base.byte(at: position) == 9
            else {
                throw NateError.message("保留 Tab 内光标需要首行完全没有实际替换。")
            }
            shape = .rectangle(
                try RectangleSelectionShape(
                    anchorX: x,
                    headX: x,
                    zeroWidth: true,
                    edges: [SelectionVirtualEdge(selectionID: entry.id, projection: layout.originProjection)],
                    anchorID: entry.id,
                    headID: entry.id,
                    layoutContext: layout.layoutContext
                )
            )
        }
        else {
            shape = .stream
        }
        let after = try SelectionState(entries: [entry], primaryID: entry.id, shape: shape)
        var edits: [TextEdit] = []
        if let removal = layout.baseRemoval {
            // 临时删除只用于布局。反向映射的两侧归属让原删除与后续行内替换相邻，不能重复吞掉原文。
            let inverse = PositionMap(validatedChanges: [
                PositionChange(
                    range: ByteRange(removal.lower, removal.lower),
                    insertedByteCount: removal.count
                )
            ])
            for edit in baseEdits {
                let lower = inverse.map(edit.range.lower, affinity: .after)
                let upper = edit.range.isEmpty ? lower : inverse.map(edit.range.upper, affinity: .before)
                edits.append(TextEdit(ByteRange(lower, upper), edit.text))
            }
            edits.append(TextEdit(removal, ""))
        }
        else {
            edits = baseEdits
        }
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: after,
            name: "粘贴矩形",
            permit: allowed
        )
        try budget.check()
    }

    /// 业务作用：块输入每行恰好消费一次载荷，超过载荷的选中行只删除，不重复最后一行。
    /// 参数说明:
    /// - index: 目标在物理行序列中的位置。
    /// - content: 同一完整载荷的预备内容。
    /// - paired: 是否使用文档顺序片段逐行配对。
    /// 返回：对应真实片段、完整普通文本或明确空输入。
    private static func value(at index: Int, content: ClipboardPasteContent, paired: Bool) -> String {
        paired
            ? (index < content.documentValues.count ? content.documentValues[index] : "") : content.plainText
    }

    /// 业务作用：逐行累计全部正文与定位空白，超额时尚未创建填充字符串。
    /// 参数说明:
    /// - size: 此行完整输出字节数。
    /// - total: 已通过容量门禁的全部输出。
    /// 返回：合计不超过 256 MiB 时更新计数，否则失败。
    private static func add(_ size: Int, to total: inout Int) throws {
        guard size >= 0, size <= 256 * 1024 * 1024 - total else {
            throw NateError.message("块粘贴与全部空白超过 256 MiB。")
        }
        total += size
    }
}
