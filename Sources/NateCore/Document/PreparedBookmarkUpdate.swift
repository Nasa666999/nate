import Foundation

struct PreparedBookmarkUpdate: Sendable {
    let generation: UUID
    let lines: Set<Int>
}

extension PreparedTransaction {
    /// 业务作用：将书签行操作的目标集合纳入正文事务及撤销历史，避免先改正文再单独覆盖元数据。
    /// 参数说明:
    /// - lines: 结果正文中应保留的零起始逻辑行，最多 100000 项。
    /// - expectedGeneration: 准备时捕获的书签状态身份，往返变动后同样失效。
    /// 返回：带书签发布条件的新事务；非法行或容量超限时拒绝，原事务与文档保持不变。
    public func assigningBookmarks(
        _ lines: Set<Int>,
        expectedGeneration: UUID
    ) throws -> PreparedTransaction {
        guard lines.count <= 100_000,
            lines.allSatisfy({
                $0 >= 0 && $0 < after.lineCount
            })
        else {
            throw NateError.message("书签结果超出有效逻辑行或 100000 项容量。")
        }
        var result = self
        result.bookmarkUpdate = PreparedBookmarkUpdate(
            generation: expectedGeneration,
            lines: lines
        )
        return result
    }
}
