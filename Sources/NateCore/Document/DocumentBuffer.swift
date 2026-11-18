import Foundation

public struct TextEdit: Sendable {
    public var range: ByteRange
    public var text: String

    /// 业务作用：描述基于同一编辑前快照的一项修改。
    /// 参数说明:
    /// - range: 被替换范围。
    /// - text: 新正文片段。
    /// 返回：尚未发布的修改意图。
    public init(_ range: ByteRange, _ text: String) {
        self.range = range
        self.text = text
    }
}

public struct PositionChange: Sendable {
    public let range: ByteRange
    public let insertedByteCount: Int
}

public struct DocumentSnapshot: Sendable {
    public let id: UUID
    public let revision: UInt64
    public let text: PieceTree
    public let format: DocumentFormat

    /// 业务作用：将不可变正文绑定到后台任务与排版所需身份。
    /// 参数说明:
    /// - id: 所属文档生命周期。
    /// - revision: 单调正文修订。
    /// - text: 结构共享的正文。
    /// - format: 同一修订的持久化参数。
    /// 返回：可跨执行域传递的快照。
    public init(id: UUID, revision: UInt64, text: PieceTree, format: DocumentFormat = .utf8) {
        self.id = id
        self.revision = revision
        self.text = text
        self.format = format
    }
}

@MainActor
public final class DocumentBuffer {
    public let id: UUID
    public private(set) var revision: UInt64 = 0
    public private(set) var text: PieceTree
    public private(set) var format: DocumentFormat
    public var selections = [TextSelection(anchor: 0, head: 0)] {
        didSet {
            if oldValue != selections {
                selectionGeneration = UUID()
            }
        }
    }
    public private(set) var selectionGeneration = UUID()
    public var isReadOnly = false {
        didSet {
            if oldValue != isReadOnly {
                // 权限恢复原值也属于新的控制状态，等待中的旧动作不能重新取得编辑资格。
                editingAuthorityGeneration = UUID()
            }
        }
    }
    public var isEditingSuspended = false {
        didSet {
            if oldValue != isEditingSuspended {
                // 进入和解除保护都收回旧资格，不能只在发布时比较最终布尔值。
                editingAuthorityGeneration = UUID()
            }
        }
    }
    public private(set) var editingAuthorityGeneration = UUID()
    public var bookmarks: Set<Int> = [] {
        didSet {
            // 书签独立于正文修订，任何重新赋值或往返变动都撤销旧书签计划的发布资格。
            bookmarkGeneration = UUID()
        }
    }
    public private(set) var bookmarkGeneration = UUID()
    public internal(set) var marks = DocumentMarkState()
    public internal(set) var markGeneration = UUID()
    public var modifiedLines: Set<Int> = []
    public var historyLimit = 1000
    public var historyByteLimit = 256 * 1024 * 1024
    public private(set) var discardedHistoryEntries = 0
    public var historyRetainedBytes: Int {
        undoEntries.reduce(0) {
            $0 + $1.retainedBytes
        }
            + redoEntries.reduce(0) {
                $0 + $1.retainedBytes
            }
    }
    public private(set) var lastEdits: [TextEdit] = []
    public private(set) var lastChanges: [PositionChange] = []
    public private(set) var lastActionName = ""
    public private(set) var historyFailure: String?
    private var undoEntries: [HistoryEntry] = []
    private var redoEntries: [HistoryEntry] = []
    var positionJournal: [RevisionPositionMap] = []
    var positionJournalChanges = 0
    public var canUndo: Bool {
        !undoEntries.isEmpty && !isReadOnly && !isEditingSuspended && revision < UInt64.max
    }
    public var canRedo: Bool {
        !redoEntries.isEmpty && !isReadOnly && !isEditingSuspended && revision < UInt64.max
    }
    public var snapshot: DocumentSnapshot {
        DocumentSnapshot(id: id, revision: revision, text: text, format: format)
    }

    /// 业务作用：建立独立于路径和视图的文档生命周期。
    /// 参数说明:
    /// - text: 初始正文。
    /// - id: 恢复记录的稳定身份；新打开默认新建。
    /// - format: 初始格式，不制造额外撤销项。
    /// - revision: 已确认的恢复修订，新文档默认为零。
    /// 返回：串行事务控制的文档。
    public init(text: String = "", id: UUID = UUID(), format: DocumentFormat = .utf8, revision: UInt64 = 0) {
        self.id = id
        self.text = PieceTree(text)
        self.format = format
        self.revision = revision
    }

    /// 业务作用：后台加载或恢复已经构建好的分块正文在主执行域直接接管，不再展开全文。
    /// 参数说明:
    /// - text: 已验证的不可变分块正文。
    /// - id: 文档生命周期。
    /// - format: 原始编码和换行规则。
    /// - revision: 已确认的恢复修订，不将恢复身份的序号重置为零。
    /// 返回：正文结构共享的新文档，不制造撤销项。
    public init(text: PieceTree, id: UUID = UUID(), format: DocumentFormat = .utf8, revision: UInt64 = 0) {
        self.id = id
        self.text = text
        self.format = format
        self.revision = revision
    }

    /// 业务作用：唯一正文提交入口，全部校验完成后一次发布历史、选区和单调修订。
    /// 参数说明:
    /// - edits: 全部基于当前修改前快照的修改。
    /// - expectedRevision: 后台计划必须匹配的起始修订。
    /// - selectionsAfter: 可选的完整结果选区。
    /// - formatAfter: 可选的一并发布格式。
    /// - name: 用户可理解的撤销动作名称。
    /// 返回：有实际字节变化时发布新修订；失败不留下部分修改。
    @discardableResult
    public func commit(
        _ edits: [TextEdit],
        expectedRevision: UInt64? = nil,
        selectionsAfter: [TextSelection]? = nil,
        formatAfter: DocumentFormat? = nil,
        name: String = "编辑"
    ) throws -> Bool {
        // 只读和过期计划必须在准备任何正文发布之前拒绝。
        guard !isReadOnly else {
            throw NateError.readOnly
        }
        // 关闭边界固定最终修订，持久化确认之前不再接受新的写入事务。
        guard !isEditingSuspended else {
            throw NateError.message("文档正在完成关闭或文件目标操作。")
        }
        guard expectedRevision == nil || expectedRevision == revision else {
            throw NateError.staleRevision
        }
        return try commit(
            PreparedTransaction(
                snapshot: snapshot,
                edits: edits,
                selectionsAfter: selectionsAfter,
                formatAfter: formatAfter,
                name: name
            )
        )
    }

    /// 业务作用：后台事务在主执行域短时复验后发布，过期计划没有任何部分效果。
    /// 参数说明:
    /// - transaction: 完成全部正文构建和范围校验的不可变事务。
    /// 返回：实际修改发布新修订与撤销项；只读、关闭或证据变化时拒绝。
    @discardableResult
    public func commit(_ transaction: PreparedTransaction) throws -> Bool {
        // 后台准备期间可能失去编辑权限或改变正文，发布前必须重新检查。
        guard !isReadOnly else {
            throw NateError.readOnly
        }
        guard !isEditingSuspended else {
            throw NateError.message("文档正在完成关闭或文件目标操作。")
        }
        guard transaction.documentID == id, transaction.revision == revision,
            transaction.before.byteEqual(to: text)
        else {
            throw NateError.staleRevision
        }
        // 正文修订不包含书签变化，关联行计划还须持有最初的书签身份才能发布。
        guard
            transaction.bookmarkUpdate.map({
                $0.generation == bookmarkGeneration
            }) ?? true
        else {
            throw NateError.staleRevision
        }
        // 颜色独立于正文修订，不能在后台排序之后覆盖用户刚清除或重新设置的样式。
        guard
            transaction.markUpdate.map({
                $0.generation == markGeneration
            }) ?? true
        else {
            throw NateError.staleRevision
        }
        let unique = transaction.edits
        let changes = transaction.changes
        let positions = transaction.positions
        let formatAfter = transaction.format
        let name = transaction.name
        guard
            !changes.isEmpty
                || formatAfter.map({
                    $0 != format
                }) == true
        else {
            // 空末行没有可删除字节，仍解除其书签；这类元数据动作不制造正文历史。
            if let update = transaction.bookmarkUpdate {
                bookmarks = update.lines
            }
            lastEdits = []
            lastActionName = ""
            return false
        }
        // 修订不能回绕到旧值，否则旧范围与后台结果可能重新取得发布资格。
        guard revision < UInt64.max else {
            throw NateError.message("文档修订已达到上限，请保存后关闭并重新打开，建立新的文档生命周期。")
        }
        let prepared = transaction.after
        let preparedMarks =
            try transaction.markUpdate?.state ?? prepareDocumentMarkMapping(positions, in: prepared)
        let after =
            transaction.selections
            ?? normalizedSelections().map {
                TextSelection(
                    anchor: positions.map($0.anchor),
                    head: positions.map($0.head),
                    virtualColumn: $0.virtualColumn
                )
            }
        guard
            after.allSatisfy({
                prepared.isBoundary($0.anchor) && prepared.isBoundary($0.head)
            })
        else {
            throw NateError.invalidRange
        }
        let bookmarksAfter: Set<Int>
        if let update = transaction.bookmarkUpdate {
            bookmarksAfter = update.lines
        }
        else {
            let mapped = bookmarks.map {
                positions.map(text.lineStart($0))
            }
            bookmarksAfter = Set(
                mapped.map {
                    prepared.lineNumber(at: min($0, prepared.byteCount))
                }
            )
        }
        let backwardChanges = Self.inverseChanges(changes)
        let backwardPositions = transaction.reversePositions ?? PositionMap(validatedChanges: backwardChanges)
        let entry = HistoryEntry(
            before: text,
            after: prepared,
            selectionsBefore: selections,
            selectionsAfter: after,
            formatBefore: format,
            formatAfter: formatAfter ?? format,
            bookmarksBefore: bookmarks,
            bookmarksAfter: bookmarksAfter,
            forwardChanges: changes,
            backwardChanges: backwardChanges,
            forwardPositions: positions,
            backwardPositions: backwardPositions,
            retainedBytes: changes.reduce(512 + positions.retainedBytes + backwardPositions.retainedBytes) {
                $0 + $1.range.count + $1.insertedByteCount + 4096
            },
            name: name
        )
        // 正文和历史同一串行发布，保存调度无法观察准备中的中间状态。
        text = prepared
        format = formatAfter ?? format
        lastEdits = unique
        lastChanges = entry.forwardChanges
        lastActionName = name
        selections = after
        publishDocumentMarks(preparedMarks)
        recordPositions(positions)
        revision += 1
        undoEntries.append(entry)
        var retained = undoEntries.reduce(0) {
            $0 + $1.retainedBytes
        }
        // 至少保留最后一个原子操作；更早正文按容量与数量双重预算释放。
        while undoEntries.count > max(1, historyLimit)
            || (undoEntries.count > 1 && retained > max(0, historyByteLimit))
        {
            retained -= undoEntries.removeFirst().retainedBytes
            discardedHistoryEntries += 1
        }
        redoEntries.removeAll()
        historyFailure = nil
        bookmarks = bookmarksAfter
        modifiedLines.formUnion(
            changes.map {
                text.lineNumber(at: min($0.range.lower, text.byteCount))
            }
        )
        return true
    }

    /// 业务作用：将相交、重复和落在非空选区起点的空光标归并，正文每处只修改一次。
    /// 参数说明: 无。
    /// 返回：按文档顺序排列的不交叠选区。
    public func normalizedSelections() -> [TextSelection] {
        let sorted = selections.sorted {
            $0.range.lower < $1.range.lower
        }
        var result: [TextSelection] = []
        for selection in sorted {
            if let last = result.last,
                selection.range.lower < last.range.upper || selection.range == last.range
                    || last.range.isEmpty && selection.range.lower == last.range.lower
            {
                result[result.count - 1] = TextSelection(
                    anchor: last.range.lower,
                    head: max(last.range.upper, selection.range.upper)
                )
            }
            else {
                result.append(selection)
            }
        }
        return result
    }

    /// 业务作用：一次输入、粘贴或输入法确认对所有有效光标形成同一撤销单元。
    /// 参数说明:
    /// - value: 插入文字，不解释剪贴板转义。
    /// - name: 撤销动作名称。
    /// 返回：原子提交结果；只读时拒绝。
    public func insert(_ value: String, name: String = "输入") throws {
        let targets = normalizedSelections()
        var delta = 0
        let after = targets.map {
            selection -> TextSelection in
            let position = selection.range.lower + delta + value.utf8.count + selection.virtualColumn
            delta += value.utf8.count + selection.virtualColumn - selection.range.count
            return TextSelection(anchor: position, head: position)
        }
        try commit(
            targets.map {
                TextEdit($0.range, String(repeating: " ", count: $0.virtualColumn) + value)
            },
            selectionsAfter: after,
            name: name
        )
    }

    /// 业务作用：撤销完整编辑并恢复操作前选区，保存不参与历史管理。
    /// 参数说明: 无。
    /// 返回：恢复旧正文但使用新修订号；权限或修订上限保留正文与历史，颜色映射失败还会提供具体原因。
    public func undo() {
        performHistory(backwards: true)
    }

    /// 业务作用：重做完整事务；新输入后旧分支不再可用。
    /// 参数说明: 无。
    /// 返回：恢复事务结果和新修订号；权限或修订上限保留正文与历史，颜色映射失败还会提供具体原因。
    public func redo() {
        performHistory(backwards: false)
    }

    /// 业务作用：串行固定当前历史顶端及独立元数据，供后台准备而不提前消费撤销项。
    /// 参数说明:
    /// - backwards: 为真准备撤销，为假准备重做。
    /// 返回：具备执行条件的不可变请求；无历史、只读、保护或修订上限时不产生请求。
    public func historyRequest(backwards: Bool) -> DocumentHistoryRequest? {
        historyFailure = nil
        // 保护、权限与单调上限都先于历史读取，等待过程不能取得提前消费历史的权利。
        guard !isReadOnly, !isEditingSuspended, revision < UInt64.max,
            let entry = backwards ? undoEntries.last : redoEntries.last
        else {
            return nil
        }
        return DocumentHistoryRequest(
            documentID: id,
            revision: revision,
            editing: editingAuthorityGeneration,
            markGeneration: markGeneration,
            bookmarkGeneration: bookmarkGeneration,
            selectionGeneration: selectionGeneration,
            selections: selections,
            marks: marks,
            entry: entry,
            backwards: backwards
        )
    }

    /// 业务作用：复验后台历史动作的完整控制证据，再一次发布正文、选区、书签、颜色和双向历史。
    /// 参数说明:
    /// - action: 已完成全部可失败颜色准备的历史动作。
    /// 返回：成功推进新修订；正文、权限、选区或元数据改变时拒绝且保留全部当前状态。
    public func commitHistory(_ action: PreparedHistoryAction) throws {
        let request = action.request
        // 元数据与权限可在同一正文修订内往返变化，必须分别复验身份而不是只比较最后内容。
        guard !isReadOnly, !isEditingSuspended, revision < UInt64.max,
            request.documentID == id, request.revision == revision,
            request.editing == editingAuthorityGeneration,
            request.markGeneration == markGeneration, request.bookmarkGeneration == bookmarkGeneration,
            request.selectionGeneration == selectionGeneration, request.selections == selections,
            request.entry.id == (request.backwards ? undoEntries.last?.id : redoEntries.last?.id)
        else {
            throw NateError.staleRevision
        }
        let entry = request.entry
        // 所有可失败计算已结束，历史栈和正文从这里开始作为同一串行动作发布。
        if request.backwards {
            _ = undoEntries.popLast()
            redoEntries.append(entry)
        }
        else {
            _ = redoEntries.popLast()
            undoEntries.append(entry)
        }
        text = request.backwards ? entry.before : entry.after
        format = request.backwards ? entry.formatBefore : entry.formatAfter
        bookmarks = request.backwards ? entry.bookmarksBefore : entry.bookmarksAfter
        lastEdits = []
        lastChanges = request.backwards ? entry.backwardChanges : entry.forwardChanges
        lastActionName = entry.name
        selections = request.backwards ? entry.selectionsBefore : entry.selectionsAfter
        publishDocumentMarks(action.marks)
        recordPositions(request.backwards ? entry.backwardPositions : entry.forwardPositions)
        revision += 1
        historyFailure = nil
    }

    /// 业务作用：同步调用者复用与后台历史相同的准备和发布门禁，不产生第二套撤销行为。
    /// 参数说明:
    /// - backwards: 为真撤销，为假重做。
    /// 返回：准备失败时保留正文与历史并记录原因，成功时完整切换当前状态。
    private func performHistory(backwards: Bool) {
        guard let request = historyRequest(backwards: backwards) else {
            return
        }
        do {
            try commitHistory(PreparedHistoryAction(request))
        }
        catch {
            // 未完整准备的颜色不能消费历史；用户减少范围后仍可重新执行同一个动作。
            historyFailure = (backwards ? "撤销" : "重做") + "未执行，正文与历史保留：" + error.localizedDescription
        }
    }

    /// 业务作用：将其他视图和标记的位置随同一事务映射。
    /// 参数说明:
    /// - position: 修改前位置。
    /// - edits: 已排序的修改列表。
    /// 返回：删除内位置收拢到新片段末端，边界插入归属于后侧。
    public nonisolated static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        map(
            position,
            through: edits.map {
                PositionChange(range: $0.range, insertedByteCount: $0.text.utf8.count)
            }
        )
    }

    /// 业务作用：按不携带正文的变换索引移动克隆光标与标记。
    /// 参数说明:
    /// - position: 修改前字节位置。
    /// - changes: 同一快照上的有序范围变换。
    /// 返回：被删除位置归于新片段末端，未涉及位置保持相对文本关系。
    public nonisolated static func map(_ position: Int, through changes: [PositionChange]) -> Int {
        var delta = 0
        for edit in changes {
            if position < edit.range.lower {
                break
            }
            if position <= edit.range.upper {
                return edit.range.lower + delta + edit.insertedByteCount
            }
            delta += edit.insertedByteCount - edit.range.count
        }
        return position + delta
    }

    /// 业务作用：为撤销建立反向位置映射，避免复制整段删除正文只为计算光标。
    /// 参数说明:
    /// - edits: 修改前快照上的有序位置变换。
    /// 返回：修改后快照上的反向范围变换。
    private static func inverseChanges(_ edits: [PositionChange]) -> [PositionChange] {
        var delta = 0
        return edits.map {
            edit in
            let inserted = edit.insertedByteCount
            let start = edit.range.lower + delta
            delta += inserted - edit.range.count
            return PositionChange(
                range: ByteRange(start, start + inserted),
                insertedByteCount: edit.range.count
            )
        }
    }
}
