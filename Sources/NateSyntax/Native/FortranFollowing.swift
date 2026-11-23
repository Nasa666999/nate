import Foundation
import NateCore

extension FortranScanner {
    /// 业务作用：只有真实续行或字面收束动作需要跨行时才追加固定来源，普通注释中的相同符号不扩大读取范围。
    /// 参数说明: 无。
    /// 返回：同一固定正文的下一完整物理行加入当前上下文；无来源、边界或共同容量不足时整份拒绝。
    mutating func appendFollowingLine() throws {
        try budget.check()
        // 无固定来源不能用另一个片段继续解释未结束的类别，否则后继文字会取得错误显示权限。
        guard let snapshot, base >= 0, base <= snapshot.text.byteCount,
            bytes.count < snapshot.text.byteCount - base,
            starts.last == bytes.count
        else {
            throw NateError.message("Fortran 续行缺少同一固定正文的完整后继。")
        }
        let absolute = base + bytes.count
        let row = snapshot.text.lineNumber(at: absolute)
        let range = try ANSILexing.physicalRange(
            snapshot.text.lineRange(row),
            tree: snapshot.text,
            budget: &budget
        )
        // 先确认整个后继与聚合上下文，再复制原文；超过容量时不能先分配较大的临时缓冲区。
        guard range.lower == absolute, !range.isEmpty,
            bytes.count <= 1_048_576, range.count <= 1_048_576 - bytes.count,
            snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper)
        else {
            throw NateError.message("Fortran 单行或聚合续行超过 1 MiB 或缺少完整边界。")
        }
        try budget.check()
        let following = snapshot.text.bytes(in: range)
        bytes.append(contentsOf: following)
        styles.append(contentsOf: repeatElement(UInt8(0), count: following.count))
        if following.last == 13 || following.last == 10 {
            starts.append(bytes.count)
        }
        documentEnd = range.upper == snapshot.text.byteCount
        try budget.check()
    }
}
