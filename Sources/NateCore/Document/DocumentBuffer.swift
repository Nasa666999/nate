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

struct HistoryEntry {
    var before: PieceTree
    var after: PieceTree
    var selectionsBefore: [TextSelection]
    var selectionsAfter: [TextSelection]
    var formatBefore: DocumentFormat
    var formatAfter: DocumentFormat
    var bookmarksBefore: Set<Int>
    var bookmarksAfter: Set<Int>
    var forwardChanges: [PositionChange]
    var backwardChanges: [PositionChange]
    var forwardPositions: PositionMap
    var backwardPositions: PositionMap
    var retainedBytes: Int
    var name: String
}

@MainActor
public final class DocumentBuffer {
    public let id: UUID
    public private(set) var revision: UInt64 = 0
    public private(set) var text: PieceTree
    public private(set) var format: DocumentFormat
    public var selections = [TextSelection(anchor: 0, head: 0)]
    public var isReadOnly = false
    public var isEditingSuspended = false
    public var bookmarks: Set<Int> = []
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
            lastEdits = []
            lastActionName = ""
            return false
        }
        // 修订不能回绕到旧值，否则旧范围与后台结果可能重新取得发布资格。
        guard revision < UInt64.max else {
            throw NateError.message("文档修订已达到上限，请保存后关闭并重新打开，建立新的文档生命周期。")
        }
        let prepared = transaction.after
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
        let mappedBookmarks = Set(
            bookmarks.map {
                text.lineStart($0)
            }.map {
                positions.map($0)
            }
        )
        let backwardChanges = Self.inverseChanges(changes)
        let entry = HistoryEntry(
            before: text,
            after: prepared,
            selectionsBefore: selections,
            selectionsAfter: after,
            formatBefore: format,
            formatAfter: formatAfter ?? format,
            bookmarksBefore: bookmarks,
            bookmarksAfter: Set(
                mappedBookmarks.map {
                    prepared.lineNumber(at: min($0, prepared.byteCount))
                }
            ),
            forwardChanges: changes,
            backwardChanges: backwardChanges,
            forwardPositions: positions,
            backwardPositions: PositionMap(validatedChanges: backwardChanges),
            retainedBytes: changes.reduce(512) {
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
        bookmarks = Set(
            mappedBookmarks.map {
                text.lineNumber(at: min($0, text.byteCount))
            }
        )
        modifiedLines.formUnion(
            changes.map {
                text.lineNumber(at: min($0.range.lower, text.byteCount))
            }
        )
        return true
    }

    /// 业务作用：将多光标相交或重复选区归并，正文每处只修改一次。
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
    /// 返回：恢复旧正文但使用新修订号；达到修订上限时保留正文与历史。
    public func undo() {
        // 上限检查必须先于弹出历史，不能以修订回绕或丢弃历史换取撤销。
        guard !isReadOnly, !isEditingSuspended, revision < UInt64.max, let entry = undoEntries.popLast()
        else {
            return
        }
        text = entry.before
        format = entry.formatBefore
        bookmarks = entry.bookmarksBefore
        lastEdits = []
        lastChanges = entry.backwardChanges
        selections = entry.selectionsBefore
        recordPositions(entry.backwardPositions)
        revision += 1
        redoEntries.append(entry)
    }

    /// 业务作用：重做完整事务；新输入后旧分支不再可用。
    /// 参数说明: 无。
    /// 返回：恢复事务结果和新修订号；达到修订上限时保留正文与历史。
    public func redo() {
        // 与普通提交使用相同单调门禁，达到上限后不消耗待重做事务。
        guard !isReadOnly, !isEditingSuspended, revision < UInt64.max, let entry = redoEntries.popLast()
        else {
            return
        }
        text = entry.after
        format = entry.formatAfter
        bookmarks = entry.bookmarksAfter
        lastEdits = []
        lastChanges = entry.forwardChanges
        selections = entry.selectionsAfter
        recordPositions(entry.forwardPositions)
        revision += 1
        undoEntries.append(entry)
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
