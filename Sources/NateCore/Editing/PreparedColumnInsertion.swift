import Foundation

public enum ColumnInsertionValue: Sendable {
    case text(String)
    case numbers(ColumnNumberFormat)
}

public struct PreparedColumnInsertion: Sendable {
    public let transaction: PreparedTransaction
    public let count: Int

    /// 业务作用：目标、数字与空白全部准备成功后生成一个事务，主执行域只复验并发布完整列编辑。
    /// 参数说明:
    /// - snapshot: 本轮固定正文与格式。
    /// - selections: 原视图的全部真实选择，按文档顺序编号。
    /// - value: 完整固定文本或数字格式。
    /// - tabWidth: 当前 Tab 停靠间距。
    /// 返回：完整正文事务与真实目标数；五秒、十万目标、256 MiB 输出或 1 GiB 最终正文预算不足时整体失败。
    public init(
        snapshot: DocumentSnapshot,
        selections: [TextSelection],
        value: ColumnInsertionValue,
        tabWidth: Int
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let targets = try ColumnInsertionTargets.prepare(
            text: snapshot.text,
            selections: selections,
            tabWidth: tabWidth,
            deadline: deadline
        )
        let values: [String]
        switch value {
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= 1_048_576 else {
                throw NateError.message("固定列文本须为一至 1 MiB，未截断输入。")
            }
            values = Array(repeating: text, count: targets.count)
        case .numbers(let format):
            values = try format.render(count: targets.count, deadline: deadline)
        }
        var bytes = 0, removed = 0
        for (target, value) in zip(targets, values) {
            try Self.checkpoint(deadline)
            let size = target.leadingSpaces + value.utf8.count + target.trailingSpaces
            guard size <= 268_435_456 - bytes else {
                throw NateError.message("列插入的文本与空白合计超过 256 MiB，全部目标保持原状。")
            }
            bytes += size
            removed += target.range.count
        }
        // 先核对完整最终规模，再构建正文与历史，不能在若干行已经完成后才发现整批容量不足。
        guard snapshot.text.byteCount - removed <= 1_073_741_824 - bytes else {
            throw NateError.message("列编辑后的正文超过 1 GiB，全部目标保持原状。")
        }
        var edits: [TextEdit] = [], after: [TextSelection] = []
        var delta = 0
        for (target, value) in zip(targets, values) {
            try Self.checkpoint(deadline)
            let inserted =
                String(repeating: " ", count: target.leadingSpaces) + value
                + String(repeating: " ", count: target.trailingSpaces)
            let caret = target.range.lower + delta + target.leadingSpaces + value.utf8.count
            edits.append(TextEdit(target.range, inserted))
            after.append(TextSelection(anchor: caret, head: caret))
            delta += inserted.utf8.count - target.range.count
        }
        do {
            transaction = try PreparedTransaction(
                snapshot: snapshot,
                edits: edits,
                selectionsAfter: after,
                name: "列编辑",
                permit: {
                    ContinuousClock.now < deadline
                }
            )
        }
        catch is CancellationError {
            try Task.checkCancellation()
            throw NateError.message("列编辑准备超过五秒预算，全部目标保持原状。")
        }
        count = targets.count
        try Self.checkpoint(deadline)
    }

    /// 业务作用：列编辑的数据准备和正文构建共用截止，取消不能发布已经生成的前半批目标。
    /// 参数说明:
    /// - deadline: 本轮固定截止。
    /// 返回：仍有权限与时间则继续，取消或超时完整失败。
    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("列编辑准备超过五秒预算，全部目标保持原状。")
        }
    }
}
