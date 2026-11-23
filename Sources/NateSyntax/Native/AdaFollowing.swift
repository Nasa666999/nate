import Foundation
import NateCore

extension AdaScanner {
    /// 业务作用：字符通道的原生先行步进确需跨行时才取得同源完整后继，不把不完整物理片段当成真实 EOF。
    /// 参数说明: 无。
    /// 返回：下一真实物理行及完整边界已纳入聚合上下文；容量或来源不足时整份拒绝。
    mutating func appendFollowingLine() throws {
        try budget.check()
        guard let snapshot, base >= 0, base <= snapshot.text.byteCount,
            bytes.count < snapshot.text.byteCount - base, starts.last == bytes.count
        else {
            throw NateError.message("Ada 字符通道缺少同一固定正文的完整后继。")
        }
        let absolute = base + bytes.count
        let remaining = 1_048_576 - bytes.count
        let line = snapshot.text.lineRange(snapshot.text.lineNumber(at: absolute))
        let range = try ANSILexing.physicalRange(line, tree: snapshot.text, budget: &budget)
        guard remaining > 0, range.lower == absolute, range.upper > absolute, range.count <= remaining,
            snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper)
        else {
            throw NateError.message("Ada 单行或聚合字符上下文超过 1 MiB 或缺少真实边界。")
        }
        // 聚合容量和完整来源先于复制确认，旧状态不能借用另一份正文补足字符字面。
        let following = Array(snapshot.text.text(in: range).utf8)
        guard following.count == range.count else {
            throw NateError.invalidRange
        }
        let start = bytes.count
        bytes.append(contentsOf: following)
        styles.append(contentsOf: repeatElement(0, count: following.count))
        for index in following.indices {
            try budget.consume()
            if following[index] == 10
                || following[index] == 13 && (index + 1 == following.count || following[index + 1] != 10)
            {
                starts.append(start + index + 1)
            }
        }
        documentEnd = base + bytes.count == snapshot.text.byteCount
        try budget.check()
    }
}
