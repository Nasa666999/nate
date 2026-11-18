import Foundation

struct HistoryEntry: Sendable {
    let id = UUID()
    var before: PieceTree
    var after: PieceTree
    var selectionsBefore: SelectionState
    var selectionsAfter: SelectionState
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

public struct DocumentHistoryRequest: Sendable {
    let documentID: UUID
    let revision: UInt64
    let editing: UUID
    let markGeneration: UUID
    let bookmarkGeneration: UUID
    let selectionGeneration: UUID
    let selections: [TextSelection]
    let marks: DocumentMarkState
    let entry: HistoryEntry
    let backwards: Bool
}

public struct PreparedHistoryAction: Sendable {
    let request: DocumentHistoryRequest
    let marks: DocumentMarkState

    /// 业务作用：后台完整准备撤销或重做所需的当前颜色，不从历史恢复已经清除的样式。
    /// 参数说明:
    /// - request: 文档串行捕获的历史、权限和元数据证据。
    /// - permit: 整段准备仍获准执行，为假时不返回部分颜色。
    /// 返回：未发布的完整历史动作；取消或颜色映射超量时原文档和历史不受影响。
    public init(
        _ request: DocumentHistoryRequest,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        let positions = request.backwards ? request.entry.backwardPositions : request.entry.forwardPositions
        let text = request.backwards ? request.entry.before : request.entry.after
        // 撤销目标包含完整身份与矩形，先复验目标正文边界，不能消费历史后才发现某一行形态无效。
        _ = try (request.backwards ? request.entry.selectionsBefore : request.entry.selectionsAfter)
            .validated(
                in: text,
                permit: permit
            )
        if let permutation = positions.permutation, request.marks.count > 0 {
            marks = try request.marks.relocated(by: permutation, in: text, permit: permit)
        }
        else {
            marks = request.marks.mapped(through: positions)
        }
        self.request = request
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
    }
}
