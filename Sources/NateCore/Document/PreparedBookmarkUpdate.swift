import Foundation

public struct DocumentBookmarkSnapshot: Sendable {
    public let document: DocumentSnapshot
    public let generation: UUID
    public let lines: Set<Int>

    /// 业务作用：同时固定书签、正文和独立身份，后台行移动不重新读取主执行域元数据。
    /// 参数说明:
    /// - document: 书签依附的固定文档。
    /// - generation: 书签赋值与往返变化的控制身份。
    /// - lines: 原零起始逻辑行集合。
    /// 返回：不改变正文或书签的不可变输入，具体计划仍验证容量和合法行。
    public init(document: DocumentSnapshot, generation: UUID, lines: Set<Int>) {
        self.document = document
        self.generation = generation
        self.lines = lines
    }
}

extension DocumentBuffer {
    /// 业务作用：串行取得与当前正文对应的完整书签证据，供后台整行事务使用。
    /// 参数说明: 无。
    /// 返回：结构共享正文的完整书签输入，不增加历史或推进修订。
    public var bookmarkSnapshot: DocumentBookmarkSnapshot {
        DocumentBookmarkSnapshot(document: snapshot, generation: bookmarkGeneration, lines: bookmarks)
    }
}

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
