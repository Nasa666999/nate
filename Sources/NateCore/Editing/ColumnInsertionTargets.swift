import Foundation

public struct ColumnInsertionTarget: Sendable {
    public let range: ByteRange
    public let leadingSpaces: Int
    public let trailingSpaces: Int

    /// 业务作用：列插入显式记录短行补空白与 Tab 内部拆分，不把虚拟列当成已存在正文。
    /// 参数说明:
    /// - range: 同一原快照中实际替换的正文范围。
    /// - leadingSpaces: 插入值之前需要生成的空格数量。
    /// - trailingSpaces: 被拆分 Tab 在插入值之后保留的空格数量。
    /// 返回：不持有写入权限的完整列目标。
    public init(range: ByteRange, leadingSpaces: Int = 0, trailingSpaces: Int = 0) {
        self.range = range
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
    }
}

public enum ColumnInsertionTargets {
    /// 业务作用：按文档顺序固定列目标，单光标从当前字素列延伸至末行，Tab 按明确停靠位处理。
    /// 参数说明:
    /// - text: 固定的不可变正文。
    /// - selections: 实际视图的全部原始选区，不能预先丢掉不同虚拟列。
    /// - tabWidth: 当前 Tab 停靠间距，一至三十二。
    /// - deadline: 整个列编辑共用的处理截止。
    /// 返回：最多十万项非交叠目标；字素内部光标、歧义虚拟列、超限或取消时整体拒绝。
    public static func prepare(
        text: PieceTree,
        selections: [TextSelection],
        tabWidth: Int,
        deadline: ContinuousClock.Instant
    ) throws -> [ColumnInsertionTarget] {
        let deadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        guard !selections.isEmpty, selections.count <= 100_000, (1...32).contains(tabWidth) else {
            throw NateError.message("列编辑需要一至十万个目标，Tab 停靠间距为一至三十二。")
        }
        for selection in selections {
            guard text.isBoundary(selection.anchor), text.isBoundary(selection.head),
                (0...1_048_576).contains(selection.virtualColumn)
            else {
                throw NateError.message("列目标或虚拟列不属于完整正文，已有内容保持原状。")
            }
            if selection.virtualColumn > 0 {
                let row = text.lineNumber(at: selection.range.upper)
                guard selection.range.upper == text.lineRange(row, includeEnding: false).upper else {
                    throw NateError.message("虚拟列只能位于真实行尾，未将它解释为行内的另一列。")
                }
            }
        }
        if selections.count == 1, let selected = selections.first, selected.range.isEmpty {
            let first = text.lineNumber(at: selected.head)
            guard text.lineCount - first <= 100_000 else {
                throw NateError.message("从当前列至末尾超过十万行，请明确选择较小范围。")
            }
            let column = try sourceColumn(
                text: text,
                selection: selected,
                tabWidth: tabWidth,
                deadline: deadline
            )
            var result: [ColumnInsertionTarget] = []
            for line in first..<text.lineCount {
                try checkpoint(deadline)
                result.append(
                    try target(text: text, line: line, column: column, tabWidth: tabWidth, deadline: deadline)
                )
            }
            return result
        }
        let sorted = selections.sorted {
            (a: TextSelection, b: TextSelection) -> Bool in
            if a.range.lower == b.range.lower {
                return a.range.upper < b.range.upper
            }
            return a.range.lower < b.range.lower
        }
        var merged: [TextSelection] = []
        for selection in sorted {
            try checkpoint(deadline)
            if let last = merged.last,
                selection.range.lower < last.range.upper || selection.range == last.range
                    || last.range.isEmpty && selection.range.lower == last.range.lower
            {
                // 同一点的不同虚拟列没有现成正文可区分，不能静默丢掉用户的一项目标。
                guard last.virtualColumn == selection.virtualColumn else {
                    throw NateError.message("相交目标具有不同虚拟列，请先保留明确的列选择。")
                }
                merged[merged.count - 1] = TextSelection(
                    anchor: last.range.lower,
                    head: max(last.range.upper, selection.range.upper),
                    virtualColumn: last.virtualColumn
                )
            }
            else {
                merged.append(selection)
            }
        }
        return merged.map {
            ColumnInsertionTarget(range: $0.range, leadingSpaces: $0.virtualColumn)
        }
    }

    /// 业务作用：当前列按完整扩展字形簇计数，Tab 到下个停靠位，不复制当前行的完整前缀。
    /// 参数说明:
    /// - text: 当前快照。
    /// - selection: 单个原始光标及其短行虚拟空白。
    /// - tabWidth: 当前停靠间距。
    /// - deadline: 全部目标共享的截止。
    /// 返回：准确字素列；光标位于簇内或列超过一百万时拒绝，不近似到相邻位置。
    private static func sourceColumn(
        text: PieceTree,
        selection: TextSelection,
        tabWidth: Int,
        deadline: ContinuousClock.Instant
    ) throws -> Int {
        let line = text.lineNumber(at: selection.head)
        var position = text.lineStart(line), column = 0
        var navigation = try GraphemeNavigation(text: text)
        while position < selection.head {
            try checkpoint(deadline)
            let next = try navigation.boundary(from: position, forward: true)
            guard next <= selection.head else {
                throw NateError.message("当前光标位于完整字形簇内部，未猜测列位置。")
            }
            column += text.byte(at: position) == 9 ? tabWidth - column % tabWidth : 1
            guard column <= 1_048_576 else {
                throw NateError.message("当前列超过一百万字素列，未生成部分目标。")
            }
            position = next
        }
        guard selection.virtualColumn <= 1_048_576 - column else {
            throw NateError.message("当前虚拟列超过列编辑预算。")
        }
        return column + selection.virtualColumn
    }

    /// 业务作用：把固定字素列映射为整簇边界，短行延长，落在 Tab 内部时保留其两侧空白。
    /// 参数说明:
    /// - text: 原始完整正文。
    /// - line: 本次目标逻辑行。
    /// - column: 需要到达的非负字素列。
    /// - tabWidth: Tab 停靠间距。
    /// - deadline: 整个计划共用截止。
    /// 返回：原文中的实际替换与空白意图；不切开中文、组合、Emoji 或 CRLF。
    private static func target(
        text: PieceTree,
        line: Int,
        column: Int,
        tabWidth: Int,
        deadline: ContinuousClock.Instant
    ) throws -> ColumnInsertionTarget {
        let row = text.lineRange(line, includeEnding: false)
        var position = row.lower, current = 0
        var navigation = try GraphemeNavigation(text: text)
        while position < row.upper && current < column {
            try checkpoint(deadline)
            let next = try navigation.boundary(from: position, forward: true)
            let width = text.byte(at: position) == 9 ? tabWidth - current % tabWidth : 1
            if current + width > column {
                return ColumnInsertionTarget(
                    range: ByteRange(position, next),
                    leadingSpaces: column - current,
                    trailingSpaces: current + width - column
                )
            }
            current += width
            position = next
        }
        return ColumnInsertionTarget(
            range: ByteRange(position, position),
            leadingSpaces: max(0, column - current)
        )
    }

    /// 业务作用：列目标遍历共用真实取消与截止，不能为每一行重新取得完整处理时间。
    /// 参数说明:
    /// - deadline: 整个列编辑动作的固定截止。
    /// 返回：仍有效则继续；取消或超时整体失败，不返回前面若干行。
    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("列目标准备超过五秒预算，全部目标保持原状。")
        }
    }
}
