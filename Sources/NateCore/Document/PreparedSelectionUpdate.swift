import Foundation

struct PreparedSelectionUpdate: Sendable {
    let generation: UUID
    let before: SelectionState
    let after: SelectionState
}

extension PreparedTransaction {
    /// 业务作用：后台完成完整选择的范围、主项和身份准备，主线程正文发布不再执行大批选择归并。
    /// 参数说明:
    /// - snapshot: 原文档和完整选择控制证据。
    /// - explicitState: 可选的明确结果身份与形态，必须与显式结果几何一致。
    /// - permit: 正文和选择准备共用的执行资格。
    /// 返回：附带独立发布门禁的完整选择结果；缺失原状态、非法边界或取消时不返回部分元数据。
    mutating func prepareSelectionUpdate(
        snapshot: DocumentSnapshot,
        explicitState: SelectionState? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard let generation = snapshot.selectionGeneration else {
            guard snapshot.selectionState == nil, explicitState == nil else {
                throw NateError.message("完整选择结果需要原文档的选择控制身份。")
            }
            return
        }
        guard let original = snapshot.selectionState else {
            throw NateError.message("原选择集合无法完整表示，请先重新选择正文。")
        }
        _ = try original.validated(in: before, permit: permit)
        let result: SelectionState
        if let explicitState {
            guard selections == nil || selections == explicitState.selections else {
                throw NateError.message("显式结果选择与完整形态不一致，正文保持原状。")
            }
            result = try explicitState.validated(in: after, permit: permit)
        }
        else {
            let mapped: SelectionState
            if changes.isEmpty {
                mapped = original
            }
            else {
                mapped = try original.normalized(in: before, permit: permit).mapped(
                    through: positions,
                    in: after,
                    preservingRectangle: positions.permutation != nil,
                    permit: permit
                )
            }
            let prepared =
                try selections.map {
                    try mapped.replacingGeometries($0, permit: permit)
                } ?? mapped
            result = try prepared.validated(in: after, permit: permit)
        }
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        selectionUpdate = PreparedSelectionUpdate(generation: generation, before: original, after: result)
    }
}
