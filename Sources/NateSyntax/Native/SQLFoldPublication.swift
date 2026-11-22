import Foundation
import NateCore

extension SQLFolding {
    /// 业务作用：完整原生层级统一换算为实际显示行范围，发布前确认全部父子边界和容量。
    /// 参数说明:
    /// - levels: 已完整扫描的物理行层级。
    /// - snapshot: 本轮固定正文及显示行坐标。
    /// - budget: 当前折叠共享的步骤与截止预算。
    /// 返回：最多 65536 个有子行的完整折叠范围；超量或取消时不返回部分结果。
    static func publish(
        _ levels: [SQLFoldLevel],
        snapshot: DocumentSnapshot,
        budget: inout ANSILexingBudget
    ) throws -> [FoldRegion] {
        var ends = Array(repeating: levels.count - 1, count: levels.count)
        var stack: [Int] = []
        for index in levels.indices {
            try budget.consume()
            while let parent = stack.last, levels[index].level <= levels[parent].level {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if levels[index].header {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in levels.indices where levels[index].header {
            try budget.consume()
            let start = levels[index].start, end = levels[ends[index]].end
            if end <= start {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("SQL 折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(
                        snapshot.text.lineRange(start).lower,
                        snapshot.text.lineRange(end).upper
                    ),
                    startLine: start,
                    endLine: end,
                    level: 0
                )
            )
        }
        // 状态和全部行范围确认完成后才交付折叠，迟到取消不能使部分正文被隐藏。
        try budget.check()
        return output
    }
}
