import Foundation
import NateCore

private struct ClosedRecoveryIndex: Codable {
    var format = 1
    var documents: [RecoveryReference]
}

extension RecoveryStore {
    /// 业务作用：关闭临时文档前将有效快照加入独立保留清单，不能只依赖内存历史。
    /// 参数说明:
    /// - reference: 已完成正文和索引持久化的快照。
    /// 返回：最近 100 份关闭内容的可靠索引，原工作区仍可继续更新。
    public func archive(_ reference: RecoveryReference) throws {
        var references = try archivedReferences()
        references.removeAll {
            $0.id == reference.id
        }
        references.insert(reference, at: 0)
        references = Array(references.prefix(100))
        let url = directory.appendingPathComponent("closed-index.json")
        let expected = FileManager.default.fileExists(atPath: url.path) ? try FileStorage.baseline(url) : nil
        _ = try FileStorage.save(
            try JSONEncoder().encode(ClosedRecoveryIndex(documents: references)),
            to: url,
            expected: expected
        )
    }

    /// 业务作用：只读取恢复保留清单的轻量元数据，不同时载入大量已关闭正文。
    /// 参数说明: 无。
    /// 返回：按关闭顺序排列的快照引用。
    public func archivedReferences() throws -> [RecoveryReference] {
        let url = directory.appendingPathComponent("closed-index.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else {
            throw NateError.message("恢复保留索引超过 1 MB。")
        }
        let index = try JSONDecoder().decode(ClosedRecoveryIndex.self, from: data)
        guard index.format == 1, index.documents.count <= 100 else {
            throw NateError.message("恢复保留清单格式或数量超出支持范围。")
        }
        return index.documents
    }

    /// 业务作用：用户选择后才读取一个归档正文，并核验身份和完整性。
    /// 参数说明:
    /// - reference: 用户选中的恢复引用。
    /// 返回：完整可恢复正文；损坏记录不被当成空文档。
    public func loadArchived(_ reference: RecoveryReference) throws -> RecoveryDocument {
        guard !reference.file.contains("/"), !reference.file.contains("..") else {
            throw NateError.invalidRange
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(reference.file))
        guard FileStorage.digest(data) == reference.checksum else {
            throw NateError.message("恢复内容完整性校验失败。")
        }
        let document = try JSONDecoder().decode(RecoveryDocument.self, from: data)
        guard document.id == reference.id else {
            throw NateError.message("恢复内容身份不匹配。")
        }
        return document
    }
}
