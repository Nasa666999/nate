import Foundation

public struct PreparedLineSort: Sendable {
    public let transaction: PreparedTransaction
    public let sourceLines: [Int]
    public let selections: [TextSelection]
    public let reassignedEndings: Bool

    /// 业务作用：完整准备所选列键或整行键，移动整行正文并建立真实字节、光标与颜色的双向关系。
    /// 参数说明:
    /// - snapshot: 固定的原文档与正文。
    /// - selections: 原始实际选择，普通模式只接受一个连续选区。
    /// - rectangular: 是否来自具有明确形状证据的矩形选择，零宽矩形从各光标到行尾取键。
    /// - zeroWidthRectangle: 可选的真实零宽形状；正宽空键可明确传入假，避免扩大为行尾后缀。
    /// - options: 完整比较规则、方向和明确区域身份。
    /// - marks: 可选的原颜色快照，提供时在后台完整准备。
    /// - bookmarks: 可选的原书签快照，提供时后台准备真实行移动并绑定原身份。
    /// - permit: 整个准备过程的执行资格。
    /// 返回：最多十万行、256 MiB 原范围及键的完整事务；取消、过期、不可表示的换行边界或超量时不返回部分行序。
    public init(
        snapshot: DocumentSnapshot,
        selections: [TextSelection],
        rectangular: Bool = false,
        zeroWidthRectangle: Bool? = nil,
        options: LineSortOptions,
        marks: DocumentMarkSnapshot? = nil,
        bookmarks: DocumentBookmarkSnapshot? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = LineSortBudget(deadline: .now.advanced(by: .seconds(30)), permit: permit)
        try budget.check()
        let input = try Self.scope(
            in: snapshot.text,
            selections: selections,
            rectangular: rectangular,
            zeroWidthRectangle: zeroWidthRectangle,
            budget: budget
        )
        let first = input.first
        let last = input.last
        guard last >= first else {
            transaction = try PreparedTransaction(snapshot: snapshot, edits: [], name: "行排序")
            sourceLines = []
            self.selections = selections
            reassignedEndings = false
            return
        }
        guard last - first < 100_000 else {
            throw NateError.message("行排序范围最多十万行，未截断选择或读取部分行。")
        }
        let scope = ByteRange(snapshot.text.lineStart(first), snapshot.text.lineRange(last).upper)
        guard scope.count <= 256 * 1024 * 1024 else {
            throw NateError.message("行排序范围超过 256 MiB，原正文保留。")
        }
        let rows = try SortLineTable.collect(
            in: snapshot.text,
            range: scope,
            expectedCount: last - first + 1,
            budget: budget
        )
        var keys = input.keys ?? [:]
        if input.keys == nil {
            // 普通范围已经授权全部行，键直接复用顺序行表，不能再次逐行扫描行首。
            for (index, row) in rows.enumerated() {
                if index & 255 == 0 {
                    try budget.check()
                }
                keys[first + index] = row.body
            }
        }
        let slots =
            input.keys == nil
            ? Array(rows.indices)
            : keys.keys.sorted().map {
                $0 - first
            }
        var order = Array(rows.indices)
        if slots.count > 1 {
            let sorted = try Self.sorted(
                slots,
                keys: keys,
                first: first,
                text: snapshot.text,
                options: options,
                budget: budget
            )
            for (slot, source) in zip(slots, sorted) {
                order[slot] = source
            }
        }
        sourceLines = order.map {
            $0 + first
        }
        if order == Array(rows.indices) {
            transaction = try PreparedTransaction(snapshot: snapshot, edits: [], name: "行排序")
            self.selections = selections
            reassignedEndings = false
            return
        }
        var endings = Array(rows.indices)
        let joinsCRLF = order.indices.dropFirst().contains {
            rows[order[$0]].body.isEmpty && rows[$0 - 1].endingKind == 3 && rows[$0].endingKind == 1
        }
        if joinsCRLF {
            // 空正文可能使原独立 CR 与 LF 拼接，重分配原结束符可保留字节总量和空行数量。
            let nonempty = endings.filter {
                rows[$0].endingKind != 0
            }
            let grouped = nonempty.sorted {
                let a = rows[$0].endingKind, b = rows[$1].endingKind
                return a == b ? $0 < $1 : a < b
            }
            for (slot, source) in zip(nonempty, grouped) {
                endings[slot] = source
            }
        }
        let built = try Self.build(
            snapshot.text,
            rows: rows,
            order: order,
            endings: endings,
            scope: scope,
            budget: budget
        )
        // 范围边缘可能接触未选中的空行，无法在原字节内保留行数时不扩大修改权限。
        guard built.text.lineCount == snapshot.text.lineCount else {
            throw NateError.message("原独立 CR 与 LF 会在所选范围边缘拼成 CRLF，排序未执行；可扩大范围或先明确转换换行。")
        }
        self.selections = selections.map {
            TextSelection(
                anchor: built.permutation.map($0.anchor),
                head: built.permutation.map($0.head),
                virtualColumn: $0.virtualColumn
            )
        }
        reassignedEndings = endings != Array(rows.indices)
        do {
            let prepared = try PreparedTransaction(
                permuting: snapshot,
                to: built.text,
                using: built.permutation,
                selectionsAfter: self.selections,
                marks: marks,
                name: "行排序",
                permit: {
                    !Task.isCancelled && permit() && ContinuousClock.now < budget.deadline
                }
            )
            if let bookmarks {
                transaction = try Self.movingBookmarks(
                    bookmarks,
                    transaction: prepared,
                    sourceLines: sourceLines,
                    first: first,
                    budget: budget
                )
            }
            else {
                transaction = prepared
            }
        }
        catch {
            try budget.check()
            throw error
        }
        try budget.check()
    }

    /// 业务作用：明确普通连续选择和矩形列选择的权限，不把多个任意光标推测为全文范围。
    /// 参数说明:
    /// - text: 固定源正文。
    /// - selections: 完整实际选择。
    /// - rectangular: 是否具有矩形来源证据。
    /// - zeroWidthRectangle: 可选的真实零宽证据，未提供时按全部实际空范围判断。
    /// - budget: 行范围确认与后续准备共用的执行资格。
    /// 返回：首末逻辑行与矩形完整键；普通范围的键由顺序行表提供，交叠或跨行矩形时整体拒绝。
    private static func scope(
        in text: PieceTree,
        selections: [TextSelection],
        rectangular: Bool,
        zeroWidthRectangle: Bool?,
        budget: LineSortBudget
    ) throws -> (first: Int, last: Int, keys: [Int: ByteRange]?) {
        try budget.check()
        guard !selections.isEmpty, selections.count <= 100_000,
            selections.allSatisfy({
                text.isBoundary($0.anchor) && text.isBoundary($0.head) && $0.virtualColumn >= 0
            })
        else {
            throw NateError.invalidRange
        }
        if rectangular {
            let empty = selections.allSatisfy {
                $0.range.isEmpty
            }
            let zeroWidth = zeroWidthRectangle ?? empty
            guard !zeroWidth || empty else {
                throw NateError.message("零宽矩形不能包含非空行内范围。")
            }
            var keys: [Int: ByteRange] = [:]
            for (index, selection) in selections.enumerated() {
                if index & 255 == 0 {
                    try budget.check()
                }
                let row = text.lineNumber(at: selection.range.lower)
                let body = text.lineRange(row, includeEnding: false)
                guard selection.range.upper <= body.upper, keys[row] == nil,
                    selection.virtualColumn == 0 || selection.range.isEmpty && selection.head == body.upper
                else {
                    throw NateError.message("矩形排序要求每行一个行内目标，虚拟列只能位于真实行尾。")
                }
                keys[row] = zeroWidth ? ByteRange(selection.head, body.upper) : selection.range
            }
            guard let first = keys.keys.min(), let last = keys.keys.max() else {
                throw NateError.invalidRange
            }
            return (first, last, keys)
        }
        guard selections.count == 1, let selection = selections.first, selection.virtualColumn == 0 else {
            throw NateError.message("普通排序需要一个连续选区；多个目标请使用明确矩形选择。")
        }
        let first = selection.range.isEmpty ? 0 : text.lineNumber(at: selection.range.lower)
        var last =
            selection.range.isEmpty
            ? text.lineCount - 1 : text.lineNumber(at: selection.range.upper - 1)
        if selection.range.isEmpty, text.lineStart(last) == text.byteCount {
            last -= 1
        }
        guard last - first < 100_000 else {
            throw NateError.message("行排序范围最多十万行，未创建部分键。")
        }
        return (first, last, nil)
    }

    /// 业务作用：完整准备每个参与行的键并稳定比较，隐藏的非目标行不被借矩形范围读取为键。
    /// 参数说明:
    /// - slots: 按原顺序的真实参与行槽。
    /// - keys: 各参与逻辑行的精确字节键。
    /// - first: 范围首逻辑行。
    /// - text: 原文快照。
    /// - options: 确认的排序方式。
    /// - budget: 共同准备预算。
    /// 返回：完整源行顺序，同键保留原顺序；比较失败或取消时不提供部分顺序。
    private static func sorted(
        _ slots: [Int],
        keys: [Int: ByteRange],
        first: Int,
        text: PieceTree,
        options: LineSortOptions,
        budget: LineSortBudget
    ) throws -> [Int] {
        if options.kind == .reverse {
            return slots.reversed()
        }
        if options.kind == .random {
            var result = slots
            for index in stride(from: result.count - 1, through: 1, by: -1) {
                if index & 255 == 0 {
                    try budget.check()
                }
                result.swapAt(index, Int.random(in: 0...index))
            }
            return result
        }
        if options.kind == .locale {
            guard options.localeIdentifier.utf8.count <= 128 else {
                throw NateError.message("语言地区身份最多 128 字节。")
            }
            let identifier = Locale(identifier: options.localeIdentifier).identifier
            guard identifier.utf8.count <= 128,
                Locale.availableIdentifiers.contains(identifier)
                    || identifier == Locale.current.identifier
            else {
                throw NateError.message("请选择 macOS 可用的明确语言地区身份。")
            }
        }
        let parser =
            try (options.kind == .decimalComma || options.kind == .decimalDot) ? DecimalLineParser() : nil
        var retained = 0
        var prepared: [Int: LineSortKey] = [:]
        for slot in slots {
            do {
                guard let range = keys[slot + first] else {
                    throw NateError.invalidRange
                }
                prepared[slot] = try LineSortComparison.key(
                    in: text,
                    range: range,
                    options: options,
                    parser: parser,
                    retained: &retained,
                    budget: budget
                )
            }
            catch {
                try budget.check()
                throw NateError.message("第 \(slot + first + 1) 行：" + error.localizedDescription)
            }
        }
        return try slots.sorted {
            guard let a = prepared[$0], let b = prepared[$1] else {
                throw NateError.invalidRange
            }
            let result = try LineSortComparison.compare(
                a,
                b,
                options: options,
                budget: budget
            )
            if result == 0 {
                return $0 < $1
            }
            return options.descending ? result > 0 : result < 0
        }
    }

    /// 业务作用：后台完整移动书签集合，原书签改变后整份正文事务失去发布资格。
    /// 参数说明:
    /// - snapshot: 原文档和独立书签证据。
    /// - transaction: 尚未发布的完整行事务。
    /// - sourceLines: 结果各槽对应的原逻辑行。
    /// - first: 重排范围的首逻辑行。
    /// - budget: 正文和元数据共用的预算。
    /// 返回：带完整书签结果的新事务；身份、范围、容量或执行资格无效时不返回部分集合。
    private static func movingBookmarks(
        _ snapshot: DocumentBookmarkSnapshot,
        transaction: PreparedTransaction,
        sourceLines: [Int],
        first: Int,
        budget: LineSortBudget
    ) throws -> PreparedTransaction {
        guard snapshot.document.id == transaction.documentID,
            snapshot.document.revision == transaction.revision, snapshot.lines.count <= 100_000,
            try snapshot.document.text.byteEqual(to: transaction.before, permit: budget.permit)
        else {
            throw NateError.staleRevision
        }
        var destinations: [Int: Int] = [:]
        for (index, source) in sourceLines.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            destinations[source] = first + index
        }
        var lines: Set<Int> = []
        for (index, line) in snapshot.lines.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            guard line >= 0, line < transaction.before.lineCount else {
                throw NateError.invalidRange
            }
            lines.insert(destinations[line] ?? line)
        }
        try budget.check()
        return try transaction.assigningBookmarks(lines, expectedGeneration: snapshot.generation)
    }

    /// 业务作用：只共享或切分原字节片段来建立新正文，物理结束符与行首行尾锚点分别映射。
    /// 参数说明:
    /// - text: 原始不可变正文。
    /// - rows: 范围内的完整行表。
    /// - order: 结果各槽使用的源正文行。
    /// - endings: 结果各槽使用的源行结束符。
    /// - scope: 明确允许重新排列的完整字节范围。
    /// - budget: 正文构建与索引共用的执行资格。
    /// 返回：完整新正文和双向移动索引，不展开正文或改写任何原字节。
    private static func build(
        _ text: PieceTree,
        rows: [SortableLine],
        order: [Int],
        endings: [Int],
        scope: ByteRange,
        budget: LineSortBudget
    ) throws -> (text: PieceTree, permutation: TextPermutation) {
        var pieces = [try text.slicing(ByteRange(0, scope.lower))]
        var bodies = [ByteRange](repeating: ByteRange(0, 0), count: rows.count)
        var separators = bodies
        var cursor = scope.lower
        for slot in order.indices {
            if slot & 255 == 0 {
                try budget.check()
            }
            let source = order[slot], ending = endings[slot]
            pieces.append(try text.slicing(rows[source].body))
            bodies[source] = ByteRange(cursor, cursor + rows[source].body.count)
            cursor += rows[source].body.count
            pieces.append(try text.slicing(rows[ending].ending))
            separators[ending] = ByteRange(cursor, cursor + rows[ending].ending.count)
            cursor += rows[ending].ending.count
        }
        pieces.append(try text.slicing(ByteRange(scope.upper, text.byteCount)))
        var segments: [TextRelocation] = []
        var anchors: [TextAnchorRelocation] = []
        for slot in rows.indices {
            if slot & 255 == 0 {
                try budget.check()
            }
            if !rows[slot].body.isEmpty {
                segments.append(TextRelocation(source: rows[slot].body, destination: bodies[slot]))
            }
            if !rows[slot].ending.isEmpty {
                segments.append(TextRelocation(source: rows[slot].ending, destination: separators[slot]))
            }
            anchors.append(
                TextAnchorRelocation(source: rows[slot].body.lower, destination: bodies[slot].lower)
            )
            anchors.append(
                TextAnchorRelocation(source: rows[slot].body.upper, destination: bodies[slot].upper)
            )
        }
        let result = PieceTree.joining(pieces)
        let permutation = try TextPermutation(scope: scope, segments: segments, anchors: anchors)
        try budget.check()
        return (result, permutation)
    }
}
