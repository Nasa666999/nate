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
        _ = try validateReferences([reference], deadline: .now.advanced(by: RecoveryLimits.processingTime))
        var references = try archivedReferences()
        references.removeAll {
            $0.id == reference.id
        }
        references.insert(reference, at: 0)
        references = Array(references.prefix(100))
        let url = directory.appendingPathComponent("closed-index.json")
        let expected: DiskBaseline?
        if try recoveryFileExists(url) {
            expected = try readRecoveryFile(url, maximumBytes: 1_048_576, collectBytes: false).baseline
        }
        else {
            expected = nil
        }
        let data = try JSONEncoder().encode(ClosedRecoveryIndex(documents: references))
        guard data.count <= 1_048_576 else {
            throw NateError.message("恢复保留索引超过 1 MB 预算，现有清单保持原状。")
        }
        _ = try FileStorage.save(
            data,
            to: url,
            expected: expected
        )
    }

    /// 业务作用：只读取恢复保留清单的轻量元数据，不同时载入大量已关闭正文。
    /// 参数说明: 无。
    /// 返回：按关闭顺序排列的快照引用。
    public func archivedReferences() throws -> [RecoveryReference] {
        let url = directory.appendingPathComponent("closed-index.json")
        guard try recoveryFileExists(url) else {
            return []
        }
        let data = try readRecoveryFile(url, maximumBytes: 1_048_576).data
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
        let recovered = try loadArchivedSnapshot(reference)
        var document = recovered.metadata
        document.text = recovered.text.text()
        return document
    }

    /// 业务作用：归档正文按分块直接恢复为共享树，不在应用中建立整篇中间字符串。
    /// 参数说明:
    /// - reference: 用户明确选择的一份关闭内容。
    /// 返回：完整校验的正文树和元数据，不授予原路径覆盖权限。
    public func loadArchivedSnapshot(_ reference: RecoveryReference) throws -> RecoveredSnapshot {
        try loadSnapshot(reference)
    }
}
