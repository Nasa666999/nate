import Foundation

public struct LogicalColumnReader {
    private let text: PieceTree
    private let tabWidth: Int
    private let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private let prepared: [ByteRange: ASCIITabColumns]
    private let preparedHan: [ByteRange: HanLogicalColumns]
    private var navigation: GraphemeNavigation
    private var remaining = 1_000_000
    private var line = -1
    private var position = 0
    private var currentColumn = 0
    private var nextStopColumn = 0
    private var currentStop = 0
    private var previousStop = 0

    /// 业务作用：同一批列计算共用固定正文、字素导航和预算，顺序目标复用已读前缀。
    /// 参数说明:
    /// - text: 本次完整不可变正文。
    /// - tabWidth: 已确认的 Tab 停靠间距。
    /// - deadline: 所有目标共享的截止，最多五秒。
    /// - preparedColumns: 视图已经确认的最多 1024 个长行列索引，只有同源证明可复用。
    /// - preparedHan: 同一原文中已确认的汉字或其它独立 Unicode 字母长行，逻辑列按独立字素计数。
    /// - permit: 当前操作的继续资格，失去资格后整批失败。
    /// 返回：尚未遍历正文的列读取器；非法宽度或字素导航不可用时拒绝建立。
    public init(
        text: PieceTree,
        tabWidth: Int,
        deadline: ContinuousClock.Instant,
        preparedColumns: [ASCIITabColumns] = [],
        preparedHan: [HanLogicalColumns] = [],
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard (1...32).contains(tabWidth) else {
            throw NateError.message("逻辑列计算需要 1 到 32 的 Tab 宽度。")
        }
        self.text = text
        self.tabWidth = tabWidth
        self.deadline = min(deadline, .now.advanced(by: .seconds(5)))
        self.permit = permit
        prepared = Dictionary(
            preparedColumns.prefix(ASCIITabColumns.maximumLineProjections)
                .filter { $0.matches(text, width: tabWidth) }.map { ($0.range, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.preparedHan = Dictionary(
            preparedHan.prefix(ASCIITabColumns.maximumLineProjections)
                .filter { $0.matches(text, width: tabWidth) }.map { ($0.range, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        navigation = try GraphemeNavigation(text: text)
    }

    /// 业务作用：按完整字素和实际 Tab 停靠位计算插入列，不展开完整行或把字节数当成视觉列。
    /// 参数说明:
    /// - offset: 真实正文中完整字素边界上的插入位置。
    /// - virtualColumn: 真实行尾之外需要补齐的明确空格列数。
    /// 返回：从零起的完整逻辑列；边界、虚拟列、百万步或共享截止不满足时拒绝，不提供近似结果。
    public mutating func column(at offset: Int, virtualColumn: Int = 0) throws -> Int {
        try checkpoint()
        guard text.isBoundary(offset), (0...1_000_000).contains(virtualColumn) else {
            throw NateError.invalidRange
        }
        let row = text.lineNumber(at: offset)
        let body = text.lineRange(row, includeEnding: false)
        guard offset <= body.upper, virtualColumn == 0 || offset == body.upper else {
            throw NateError.message("虚拟列只能延伸实际行尾，列计算不能切开行结束符。")
        }
        let prefixLength = offset - body.lower
        if let index = prepared[body], let column = index.column(at: prefixLength) {
            let stop = column / tabWidth * tabWidth
            guard let current = index.offset(atOrBefore: stop),
                let previous = index.offset(atOrBefore: max(0, stop - tabWidth))
            else {
                throw NateError.invalidRange
            }
            // 已验证的整行证明同时确定两处原字节停靠位，长行不会因重新遍历前缀而拒绝普通输入。
            adopt(
                row: row,
                offset: offset,
                column: column,
                stop: body.lower + current,
                previous: body.lower + previous
            )
            return column + virtualColumn
        }
        if let index = preparedHan[body], let column = index.column(at: prefixLength) {
            let stop = column / tabWidth * tabWidth
            guard let current = index.offset(atOrBefore: stop),
                let previous = index.offset(atOrBefore: max(0, stop - tabWidth))
            else {
                throw NateError.invalidRange
            }
            // 普通 Tab 采用字素逻辑列。不同原生字形宽度只影响显示，不能把像素或 UTF-8 字节当成缩进列。
            adopt(
                row: row,
                offset: offset,
                column: column,
                stop: body.lower + current,
                previous: body.lower + previous
            )
            return column + virtualColumn
        }
        if prefixLength >= 1_000_000, prefixLength <= ASCIITabColumns.maximumBytes,
            text.isPrintableASCII(in: ByteRange(body.lower, offset))
        {
            // 没有 Tab 或多字节字符的原始前缀已经由子树证明，每个字节正好占一个逻辑列。
            let stop = prefixLength / tabWidth * tabWidth
            adopt(
                row: row,
                offset: offset,
                column: prefixLength,
                stop: body.lower + stop,
                previous: body.lower + max(0, stop - tabWidth)
            )
            return prefixLength + virtualColumn
        }
        if row != line || offset < position {
            line = row
            position = body.lower
            currentColumn = 0
            nextStopColumn = tabWidth
            currentStop = body.lower
            previousStop = body.lower
        }
        while position < offset {
            try checkpoint()
            let next = try navigation.boundary(from: position, forward: true)
            guard next > position, next <= offset else {
                throw NateError.message("插入位置不是完整字形簇边界，未近似到相邻列。")
            }
            currentColumn += text.byte(at: position) == 9 ? tabWidth - currentColumn % tabWidth : 1
            guard currentColumn <= 1_000_000 else {
                throw NateError.message("逻辑列超过一百万，未准备部分输入目标。")
            }
            if currentColumn == nextStopColumn {
                previousStop = currentStop
                currentStop = next
                nextStopColumn += tabWidth
            }
            position = next
        }
        guard virtualColumn <= 1_000_000 - currentColumn else {
            throw NateError.message("虚拟列超出一百万列预算。")
        }
        return currentColumn + virtualColumn
    }

    /// 业务作用：从完整原文证明恢复列读取状态，使继续读取与前后停靠查询采用同一组端点。
    /// 参数说明:
    /// - row: 当前真实逻辑行。
    /// - offset: 已定位的原字节位置。
    /// - column: 已验证的实际前缀列数。
    /// - stop: 不超过该位置的当前停靠位原字节。
    /// - previous: 前一个停靠位原字节，行首时与当前停靠位相同。
    /// 返回：新的列读取状态，正文与选择保持原状。
    private mutating func adopt(row: Int, offset: Int, column: Int, stop: Int, previous: Int) {
        line = row
        position = offset
        currentColumn = column
        nextStopColumn = (column / tabWidth + 1) * tabWidth
        currentStop = stop
        previousStop = previous
    }

    /// 业务作用：退 Tab 的光标导航回到实际前一停靠列，Unicode 和行尾虚拟位置不会被解释成字节列。
    /// 参数说明:
    /// - selection: 当前普通选择的实际活动端及虚拟列。
    /// 返回：收束到前一停靠位的空光标；无法完整证明当前列时抛错。
    mutating func retreatToTabStop(from selection: TextSelection) throws -> TextSelection {
        let column = try column(at: selection.head, virtualColumn: selection.virtualColumn)
        let target = max(0, column - 1) / tabWidth * tabWidth
        if target >= currentColumn {
            return TextSelection(anchor: position, head: position, virtualColumn: target - currentColumn)
        }
        let stop = target == nextStopColumn - tabWidth ? currentStop : previousStop
        return TextSelection(anchor: stop, head: stop)
    }

    /// 业务作用：每次列读取都消耗同一批资格，后续目标不能重新取得完整遍历预算。
    /// 参数说明: 无。
    /// 返回：取消、截止或百万步超限时明确失败，仍有效时继续。
    private mutating func checkpoint() throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline, remaining > 0 else {
            throw NateError.message("逻辑列准备已取消或超过共享预算，正文与选择保持原状。")
        }
        remaining -= 1
    }
}
