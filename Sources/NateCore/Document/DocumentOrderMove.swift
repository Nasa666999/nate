import Foundation

public struct DocumentOrderMove: Sendable, Equatable {
    public let original: [UUID]
    public let result: [UUID]
    public let documentID: UUID
    public let sourceGeneration: UUID?

    /// 业务作用：文档重排只移动一个稳定身份，保留其余顺序，不能加入、丢弃或复制标签。
    /// 参数说明:
    /// - original: 原工作区的一至一千零二十四个唯一文档身份。
    /// - documentID: 用户明确移动的原标签。
    /// - before: 移到该原身份之前，省略时移到末尾；自身作为目标保持原顺序。
    /// - sourceGeneration: 来源标签栏的顺序控制代次，省略时仅建立不持有界面发布资格的排列意图。
    /// 返回：绑定完整原顺序和可选代次的不可变计划，发布方仍须复验来源资格；非法身份或容量拒绝。
    public init(original: [UUID], documentID: UUID, before: UUID?, sourceGeneration: UUID? = nil) throws {
        guard !original.isEmpty, original.count <= 1024, Set(original).count == original.count,
            original.contains(documentID),
            before.map({
                original.contains($0)
            }) ?? true
        else {
            throw NateError.message("标签移动需要原工作区内一至 1024 个唯一身份及明确的原目标。")
        }
        self.original = original
        self.documentID = documentID
        self.sourceGeneration = sourceGeneration
        if before == documentID {
            result = original
            return
        }
        var moved = original.filter {
            $0 != documentID
        }
        let position =
            before.flatMap {
                moved.firstIndex(of: $0)
            } ?? moved.count
        moved.insert(documentID, at: position)
        result = moved
    }
}
