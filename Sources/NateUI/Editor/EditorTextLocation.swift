import AppKit

final class EditorTextLocation: NSObject, NSTextLocation {
    let documentID: UUID
    let revision: UInt64
    let offset: Int

    /// 业务作用：绑定 TextKit 位置到文档生命周期及快照，避免跨修订复用索引。
    /// 参数说明:
    /// - documentID: 所属文档。
    /// - revision: 所属快照修订。
    /// - offset: UTF-16 单元位置。
    /// 返回：不可变位置。
    init(documentID: UUID, revision: UInt64, offset: Int) {
        self.documentID = documentID
        self.revision = revision
        self.offset = offset
    }

    /// 业务作用：让不同原生请求产生的同一文档位置具有一致相等语义，片段不能依赖对象地址识别坐标。
    /// 参数说明:
    /// - object: 待比较的系统位置对象。
    /// 返回：仅同一文档、修订和 UTF-16 偏移相等时为真。
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EditorTextLocation else {
            return false
        }
        return documentID == other.documentID && revision == other.revision && offset == other.offset
    }

    /// 业务作用：原生布局的坐标缓存按业务位置分组，与相等判定保持一致。
    /// 参数说明: 无。
    /// 返回：包含文档身份、修订和偏移的哈希值。
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(documentID)
        hasher.combine(revision)
        hasher.combine(offset)
        return hasher.finalize()
    }

    /// 业务作用：向 TextKit 提供同一快照内的逻辑排序。
    /// 参数说明:
    /// - location: 待比较位置。
    /// 返回：排序关系；不同快照按稳定身份排序，不混作相同位置。
    func compare(_ location: any NSTextLocation) -> ComparisonResult {
        guard let other = location as? EditorTextLocation else {
            return .orderedAscending
        }
        if documentID != other.documentID {
            return documentID.uuidString < other.documentID.uuidString
                ? .orderedAscending : .orderedDescending
        }
        if revision != other.revision {
            return revision < other.revision ? .orderedAscending : .orderedDescending
        }
        return offset == other.offset
            ? .orderedSame : offset < other.offset ? .orderedAscending : .orderedDescending
    }
}
