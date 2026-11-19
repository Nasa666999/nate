import Foundation

public struct ClipboardCopyProjection: Sendable {
    public let selectionID: UUID
    public let range: ByteRange
    public let leadingSpaces: Int
    public let trailingSpaces: Int

    /// 业务作用：原生视图只提供矩形的真实原文与选中 Tab 列，后台复制不再访问字体和窗口。
    /// 参数说明:
    /// - selectionID: 当前完整选择中的稳定行身份。
    /// - range: 不包含两侧被部分选中 Tab 的真实原文范围。
    /// - leadingSpaces: 起始 Tab 中实际被选中的空格列。
    /// - trailingSpaces: 结束 Tab 中实际被选中的空格列。
    /// 返回：尚未校验正文和容量的投影，不包含源路径或发布权限。
    public init(selectionID: UUID, range: ByteRange, leadingSpaces: Int = 0, trailingSpaces: Int = 0) {
        self.selectionID = selectionID
        self.range = range
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
    }
}

private struct ClipboardCopySource {
    let id: UUID
    let range: ByteRange
    let order: Int
    let reversed: Bool
    let leadingSpaces: Int
    let trailingSpaces: Int
    let virtualStart: Int
    let virtualTail: Int
    let appendsEnding: Bool
}

public struct PreparedClipboardCopy: Sendable {
    let sourceID: UUID
    let sourceRevision: UInt64
    let sourceSelection: UUID
    public let payload: ClipboardPayload
    public let plainText: String
    public let data: Data
    public let copiedLineRange: ByteRange?

    /// 业务作用：从唯一快照完整准备普通文本与形态数据，容量和取消门禁先于原文展开及剪贴板清空。
    /// 参数说明:
    /// - snapshot: 带完整选择和控制代次的原正文。
    /// - projections: 矩形所需的全部原生视觉投影，普通选择不接受此参数。
    /// - copyLineWithoutSelection: 普通空选择是否复制主光标所在整行，默认启用。
    /// - deadline: 整个复制动作的共同截止。
    /// - permit: 来源和本轮发布资格仍有效。
    /// 返回：不超过 64 MiB 普通文本及完整二进制载荷；失败不输出部分内容，不修改文档或系统剪贴板。
    public init(
        snapshot: DocumentSnapshot,
        projections: [ClipboardCopyProjection]? = nil,
        copyLineWithoutSelection: Bool = true,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, let selection = snapshot.selectionGeneration else {
            throw NateError.message("复制需要当前完整选择的身份与修订证据。")
        }
        sourceID = snapshot.id
        sourceRevision = snapshot.revision
        sourceSelection = selection
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        _ = try original.validated(in: snapshot.text, permit: allowed)
        // 缺少当前列权限时不能把旧投影变为新的剪贴板内容，剪切也依赖同一完整复制门禁。
        if case .rectangle(let rectangle) = original.shape, rectangle.needsRevalidation {
            throw NateError.message("矩形正文已经改变，请重新选择边缘后再复制。")
        }
        let sources: [ClipboardCopySource]
        let shape: ClipboardShape
        let primary: Int
        let line: ByteRange?
        switch original.shape {
        case .stream:
            guard projections == nil else {
                throw NateError.message("普通选择不能被外部投影推测成矩形。")
            }
            if original.entries.allSatisfy({
                $0.selection.range.isEmpty
            }) {
                guard copyLineWithoutSelection else {
                    throw NateError.message("当前没有可复制的正文选择。")
                }
                let row = snapshot.text.lineNumber(at: original.primary.selection.head)
                let body = snapshot.text.lineRange(row, includeEnding: false)
                sources = [
                    ClipboardCopySource(
                        id: original.primaryID,
                        range: body,
                        order: 0,
                        reversed: false,
                        leadingSpaces: 0,
                        trailingSpaces: 0,
                        virtualStart: 0,
                        virtualTail: 0,
                        appendsEnding: true
                    )
                ]
                shape = .lines
                primary = 0
                line = snapshot.text.lineRange(row)
            }
            else {
                let normalized = try original.normalized(in: snapshot.text, permit: allowed)
                let ranks = Dictionary(
                    uniqueKeysWithValues: normalized.entries.enumerated().map {
                        ($0.element.id, $0.offset)
                    }
                )
                var entries = Dictionary(
                    uniqueKeysWithValues: normalized.entries.map {
                        ($0.id, $0)
                    }
                )
                var prepared: [ClipboardCopySource] = []
                for entry in original.entries {
                    try budget.check()
                    guard let selected = entries.removeValue(forKey: entry.id), let order = ranks[entry.id]
                    else {
                        continue
                    }
                    prepared.append(
                        ClipboardCopySource(
                            id: entry.id,
                            range: selected.selection.range,
                            order: order,
                            reversed: selected.selection.anchor > selected.selection.head,
                            leadingSpaces: 0,
                            trailingSpaces: 0,
                            virtualStart: selected.selection.virtualColumn,
                            virtualTail: 0,
                            appendsEnding: false
                        )
                    )
                }
                guard
                    let index = prepared.firstIndex(where: {
                        $0.id == original.primaryID
                    })
                else {
                    throw NateError.message("复制归并后缺少原主选区。")
                }
                sources = prepared
                shape = .stream
                primary = index
                line = nil
            }
        case .rectangle(let rectangle):
            let prepared = try Self.rectangleSources(
                original,
                rectangle: rectangle,
                projections: projections,
                text: snapshot.text,
                budget: budget
            )
            sources = prepared.sources
            shape = prepared.shape
            primary = prepared.primary
            line = nil
        }
        var total = (sources.count - 1) * snapshot.format.lineEnding.text.utf8.count
        for source in sources {
            try budget.check()
            let size =
                source.range.count + source.leadingSpaces + source.trailingSpaces + source.virtualTail
                + (source.appendsEnding ? snapshot.format.lineEnding.text.utf8.count : 0)
            guard size <= ClipboardLimits.contentBytes - total else {
                throw NateError.message("复制原文、Tab 选中列与虚拟尾部合计超过 64 MiB，原剪贴板保留。")
            }
            total += size
        }
        var fragments: [ClipboardFragment] = []
        for source in sources {
            try budget.check()
            let text =
                String(repeating: " ", count: source.leadingSpaces) + snapshot.text.text(in: source.range)
                + String(repeating: " ", count: source.trailingSpaces)
                + (source.appendsEnding ? snapshot.format.lineEnding.text : "")
            fragments.append(
                try ClipboardFragment(
                    text: text,
                    documentOrder: source.order,
                    reversed: source.reversed,
                    virtualStart: source.virtualStart,
                    virtualTail: source.virtualTail
                )
            )
        }
        payload = try ClipboardPayload(
            fragments: fragments,
            primaryIndex: primary,
            shape: shape,
            lineEnding: snapshot.format.lineEnding
        )
        plainText = try payload.plainText(deadline: budget.deadline, permit: permit)
        data = try payload.encoded(deadline: budget.deadline, permit: permit)
        copiedLineRange = line
        try budget.check()
    }

    /// 业务作用：矩形投影逐项绑定原稳定身份及真实行，Tab 空格只能来自相邻实际 Tab，不复制虚拟定位空白。
    /// 参数说明:
    /// - original: 当前完整矩形选择。
    /// - rectangle: 同一选择中的视觉形态。
    /// - projections: 原生视图完整准备的逐行内容投影。
    /// - text: 所属固定正文。
    /// - budget: 全部行共用的处理资格与截止。
    /// 返回：按原建立顺序的完整来源、形态和主项；缺项、跨行、非法边缘或超量时失败。
    private static func rectangleSources(
        _ original: SelectionState,
        rectangle: RectangleSelectionShape,
        projections: [ClipboardCopyProjection]?,
        text: PieceTree,
        budget: ClipboardBudget
    ) throws -> (sources: [ClipboardCopySource], shape: ClipboardShape, primary: Int) {
        guard let projections, projections.count == original.entries.count,
            Set(projections.map(\.selectionID)).count == projections.count
        else {
            throw NateError.message("矩形复制需要每个原选择的完整原生投影。")
        }
        let byID = Dictionary(
            uniqueKeysWithValues: projections.map {
                ($0.selectionID, $0)
            }
        )
        let edges = Dictionary(
            uniqueKeysWithValues: rectangle.edges.map {
                ($0.selectionID, $0)
            }
        )
        var comparisons = 0
        let ordered = try original.entries.sorted {
            comparisons += 1
            if comparisons & 255 == 0 {
                try budget.check()
            }
            return $0.selection.range.lower < $1.selection.range.lower
        }
        let ranks = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        var sources: [ClipboardCopySource] = []
        for entry in original.entries {
            try budget.check()
            guard let projection = byID[entry.id], let edge = edges[entry.id], let order = ranks[entry.id]
            else {
                throw NateError.message("矩形复制投影未对应全部原选择。")
            }
            let row = text.lineNumber(at: entry.selection.range.lower)
            let body = text.lineRange(row, includeEnding: false)
            guard projection.range.lower >= body.lower, projection.range.upper >= projection.range.lower,
                projection.range.upper <= body.upper, text.isBoundary(projection.range.lower),
                text.isBoundary(projection.range.upper),
                (0...1_000_000).contains(projection.leadingSpaces),
                (0...1_000_000).contains(projection.trailingSpaces),
                projection.leadingSpaces == 0
                    || projection.range.lower > body.lower && text.byte(at: projection.range.lower - 1) == 9,
                projection.trailingSpaces == 0 || text.byte(at: projection.range.upper) == 9,
                entry.selection.virtualColumn == 0
                    || projection.range.isEmpty && projection.leadingSpaces == 0
                        && projection.trailingSpaces == 0
            else {
                throw NateError.message("矩形复制投影跨行或缺少真实 Tab 与虚拟边缘证据。")
            }
            var navigation = try GraphemeNavigation(text: text)
            guard
                try navigation.isBoundary(at: projection.range.lower)
                    && navigation.isBoundary(at: projection.range.upper)
            else {
                throw NateError.message("矩形复制不能切开完整字形簇。")
            }
            sources.append(
                ClipboardCopySource(
                    id: entry.id,
                    range: projection.range,
                    order: order,
                    reversed: entry.selection.anchor > entry.selection.head,
                    leadingSpaces: projection.leadingSpaces,
                    trailingSpaces: projection.trailingSpaces,
                    virtualStart: entry.selection.virtualColumn,
                    virtualTail: edge.trailingColumns,
                    appendsEnding: false
                )
            )
        }
        guard
            let primary = sources.firstIndex(where: {
                $0.id == original.primaryID
            }), let primaryRank = ranks[original.primaryID]
        else {
            throw NateError.message("矩形复制缺少明确主项。")
        }
        let head =
            rectangle.headID.flatMap {
                ranks[$0]
            } ?? (primaryRank == 0 ? 0 : sources.count - 1)
        let anchor =
            rectangle.anchorID.flatMap {
                ranks[$0]
            } ?? (head == 0 ? sources.count - 1 : 0)
        let shape = try ClipboardRectangle(
            width: abs(rectangle.headX - rectangle.anchorX),
            reversed: rectangle.headX < rectangle.anchorX,
            zeroWidth: rectangle.zeroWidth,
            anchorRow: anchor,
            headRow: head
        )
        return (sources, .rectangle(shape), primary)
    }
}
