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

public struct DocumentSnapshot: Sendable {
    public let id: UUID
    public let revision: UInt64
    public let text: PieceTree

    /// 业务作用：将不可变正文绑定到后台任务与排版所需身份。
    /// 参数说明:
    /// - id: 所属文档生命周期。
    /// - revision: 单调正文修订。
    /// - text: 结构共享的正文。
    /// 返回：可跨执行域传递的快照。
    public init(id: UUID, revision: UInt64, text: PieceTree) {
        self.id = id
        self.revision = revision
        self.text = text
    }
}

struct HistoryEntry {
    var before: PieceTree
    var after: PieceTree
    var selectionsBefore: [TextSelection]
    var selectionsAfter: [TextSelection]
    var name: String
}

@MainActor
public final class DocumentBuffer {
    public let id: UUID
    public private(set) var revision: UInt64 = 0
    public private(set) var text: PieceTree
    public var selections = [TextSelection(anchor: 0, head: 0)]
    public var isReadOnly = false
    public var bookmarks: Set<Int> = []
    public var modifiedLines: Set<Int> = []
    public var historyLimit = 1000
    public private(set) var lastEdits: [TextEdit] = []
    public private(set) var lastActionName = ""
    private var undoEntries: [HistoryEntry] = []
    private var redoEntries: [HistoryEntry] = []
    public var canUndo: Bool {
        !undoEntries.isEmpty && !isReadOnly
    }
    public var canRedo: Bool {
        !redoEntries.isEmpty && !isReadOnly
    }
    public var snapshot: DocumentSnapshot {
        DocumentSnapshot(id: id, revision: revision, text: text)
    }

    /// 业务作用：建立独立于路径和视图的文档生命周期。
    /// 参数说明:
    /// - text: 初始正文。
    /// - id: 恢复记录的稳定身份；新打开默认新建。
    /// 返回：串行事务控制的文档。
    public init(text: String = "", id: UUID = UUID()) {
        self.id = id
        self.text = PieceTree(text)
    }

    /// 业务作用：唯一正文提交入口，全部校验完成后一次发布历史、选区和单调修订。
    /// 参数说明:
    /// - edits: 全部基于当前修改前快照的修改。
    /// - expectedRevision: 后台计划必须匹配的起始修订。
    /// - selectionsAfter: 可选的完整结果选区。
    /// - name: 用户可理解的撤销动作名称。
    /// 返回：有实际字节变化时发布新修订；失败不留下部分修改。
    @discardableResult
    public func commit(
        _ edits: [TextEdit],
        expectedRevision: UInt64? = nil,
        selectionsAfter: [TextSelection]? = nil,
        name: String = "编辑"
    ) throws -> Bool {
        // 只读和过期计划必须在准备任何正文发布之前拒绝。
        guard !isReadOnly else {
            throw NateError.readOnly
        }
        guard expectedRevision == nil || expectedRevision == revision else {
            throw NateError.staleRevision
        }
        let ordered = edits.sorted {
            $0.range.lower == $1.range.lower
                ? $0.range.upper < $1.range.upper : $0.range.lower < $1.range.lower
        }
        var unique: [TextEdit] = []
        for edit in ordered {
            guard edit.range.lower <= edit.range.upper, text.isBoundary(edit.range.lower),
                text.isBoundary(edit.range.upper)
            else {
                throw NateError.invalidRange
            }
            if let previous = unique.last {
                if edit.range == previous.range && edit.text.utf8.elementsEqual(previous.text.utf8) {
                    continue
                }
                guard previous.range.upper <= edit.range.lower,
                    !(previous.range.isEmpty && previous.range == edit.range)
                else {
                    throw NateError.overlappingEdits
                }
            }
            if !text.bytes(in: edit.range).elementsEqual(edit.text.utf8) {
                unique.append(edit)
            }
        }
        guard !unique.isEmpty else {
            return false
        }
        var prepared = text
        for edit in unique.reversed() {
            prepared = try prepared.replacing(edit.range, with: edit.text)
        }
        let after =
            selectionsAfter
            ?? normalizedSelections().map {
                TextSelection(
                    anchor: Self.map($0.anchor, through: unique),
                    head: Self.map($0.head, through: unique)
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
                Self.map($0, through: unique)
            }
        )
        let entry = HistoryEntry(
            before: text,
            after: prepared,
            selectionsBefore: selections,
            selectionsAfter: after,
            name: name
        )
        // 正文和历史同一串行发布，保存调度无法观察准备中的中间状态。
        text = prepared
        lastEdits = unique
        lastActionName = name
        selections = after
        revision += 1
        undoEntries.append(entry)
        if undoEntries.count > historyLimit {
            undoEntries.removeFirst(undoEntries.count - historyLimit)
        }
        redoEntries.removeAll()
        bookmarks = Set(
            mappedBookmarks.map {
                text.lineNumber(at: min($0, text.byteCount))
            }
        )
        modifiedLines.formUnion(
            unique.map {
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
    /// 返回：恢复旧正文但使用新修订号，防止旧后台回调重新生效。
    public func undo() {
        guard !isReadOnly, let entry = undoEntries.popLast() else {
            return
        }
        text = entry.before
        selections = entry.selectionsBefore
        revision += 1
        redoEntries.append(entry)
    }

    /// 业务作用：重做完整事务；新输入后旧分支不再可用。
    /// 参数说明: 无。
    /// 返回：恢复事务结果和新修订号。
    public func redo() {
        guard !isReadOnly, let entry = redoEntries.popLast() else {
            return
        }
        text = entry.after
        selections = entry.selectionsAfter
        revision += 1
        undoEntries.append(entry)
    }

    /// 业务作用：将其他视图和标记的位置随同一事务映射。
    /// 参数说明:
    /// - position: 修改前位置。
    /// - edits: 已排序的修改列表。
    /// 返回：删除内位置收拢到新片段末端，边界插入归属于后侧。
    public static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        var delta = 0
        for edit in edits {
            if position < edit.range.lower {
                break
            }
            if position <= edit.range.upper {
                return edit.range.lower + delta + edit.text.utf8.count
            }
            delta += edit.text.utf8.count - edit.range.count
        }
        return position + delta
    }
}
