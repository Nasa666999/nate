import Foundation
import NateCore

extension RecoveryStore {
    /// 业务作用：确认完整内容依赖后可靠发布工作区索引，并独立保留上一有效记录。
    /// 参数说明:
    /// - references: 已完成持久化的文档引用，按标签顺序排列。
    /// - active: 活动文档身份，可为空。
    /// 返回：新索引已同步或既有相同字节已复验；未知格式和损坏依赖不会被自动覆盖。
    public func publish(_ references: [RecoveryReference], active: UUID?) throws {
        try FileStorage.validateFileURL(directory)
        let deadline = ContinuousClock.now.advanced(by: RecoveryLimits.processingTime)
        let hasCompleteSelections = try validateReferences(references, deadline: deadline)
        guard
            active == nil
                || references.contains(where: {
                    $0.id == active
                })
        else {
            throw NateError.message("活动文档不属于本次恢复工作区。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // 完整选择使用独立存储格式，旧程序必须拒绝读取和覆盖，不能忽略新字段后只恢复一个光标。
        let data = try encoder.encode(
            RecoveryIndex(format: hasCompleteSelections ? 3 : 2, active: active, documents: references)
        )
        guard data.count <= RecoveryLimits.metadataBytes else {
            throw NateError.message("恢复工作区索引超过 8 MB 预算。")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent("session.json")
        let previous = directory.appendingPathComponent("session.previous.json")
        var expected: DiskBaseline?
        if try recoveryFileExists(target) {
            let current = try readRecoveryIndex(target)
            expected = current.bytes.baseline
            if current.bytes.data == data {
                // 内容与活动标签均未变化时只复验现有入口，不能因为强制检查重复替换相同索引。
                return
            }
            var fallback = current.index
            let openIDs = Set(references.map(\.id))
            // 关闭身份同时从两份索引排除，当前索引受损时也不能复活已关闭内容。
            fallback.documents.removeAll {
                !openIDs.contains($0.id)
            }
            if !fallback.documents.contains(where: {
                $0.id == fallback.active
            }) {
                fallback.active = nil
            }
            // 旧索引能解码不代表其正文依赖完好，不能用失效记录覆盖唯一有效的上一索引。
            _ = try validateReferences(fallback.documents, deadline: deadline)
            let previousData = try encoder.encode(fallback)
            var old: DiskBaseline?
            if try recoveryFileExists(previous) {
                let existing = try readRecoveryIndex(previous)
                // 上一索引也可能承载较新格式或损坏现场，当前索引有效不能授予覆盖这些记录的权限。
                _ = try validateReferences(existing.index.documents, deadline: deadline)
                old = existing.bytes.baseline
            }
            _ = try FileStorage.save(previousData, to: previous, expected: old)
        }
        try checkRecoveryBudget(
            deadline,
            permit: {
                true
            }
        )
        // 全部正文分块与独立清单已经确认，最后才发布当前工作区的可恢复入口。
        _ = try FileStorage.save(data, to: target, expected: expected)
    }

    /// 业务作用：发布前有界复验所有引用和内容，分块共享只减少写入而不取消磁盘完整性检查。
    /// 参数说明:
    /// - references: 将被可靠索引引用的完整文档集合。
    /// - deadline: 本次整个索引动作的处理截止时间。
    /// 返回：身份、依赖、UTF-8 和工作区累计规模全部合法时，说明是否需要完整选择存储格式。
    func validateReferences(_ references: [RecoveryReference], deadline: ContinuousClock.Instant) throws
        -> Bool
    {
        guard references.count <= RecoveryLimits.documents,
            Set(references.map(\.id)).count == references.count
        else {
            throw NateError.message("恢复工作区文档数量或身份不合法。")
        }
        var total = 0
        var hasCompleteSelections = false
        var verified: [String: RecoveryChunkReference] = [:]
        for reference in references {
            try checkRecoveryBudget(
                deadline,
                permit: {
                    true
                }
            )
            let count: Int
            if reference.file.hasSuffix(".json") {
                let document = try JSONDecoder().decode(
                    RecoveryDocument.self,
                    from: readSnapshotData(reference)
                )
                guard document.id == reference.id else {
                    throw NateError.message("恢复文档身份不符合索引。")
                }
                _ = try document.selectionState?.validated(in: PieceTree(document.text))
                hasCompleteSelections = hasCompleteSelections || document.selectionState != nil
                count = document.text.utf8.count
            }
            else {
                let manifest = try readManifest(reference)
                hasCompleteSelections = hasCompleteSelections || manifest.metadata.selectionState != nil
                count = manifest.byteCount
                for chunk in manifest.chunks {
                    try checkRecoveryBudget(
                        deadline,
                        permit: {
                            true
                        }
                    )
                    if let existing = verified[chunk.checksum] {
                        guard existing.byteCount == chunk.byteCount, existing.utf16Count == chunk.utf16Count
                        else {
                            throw NateError.message("恢复分块存在不一致的长度声明。")
                        }
                    }
                    else {
                        let data = try readChunk(chunk)
                        guard let text = UTF8Text.decode(data),
                            text.utf16.count == chunk.utf16Count
                        else {
                            throw NateError.message("恢复分块不是长度一致的合法 UTF-8。")
                        }
                        verified[chunk.checksum] = chunk
                    }
                }
                if manifest.metadata.selectionState != nil {
                    // 索引发布会使这份选择成为恢复入口，实际正文与逐行投影也必须在发布前完整相符。
                    _ = try loadSnapshot(reference, deadline: deadline)
                }
            }
            guard count <= RecoveryLimits.documentBytes, count <= RecoveryLimits.workspaceBytes - total else {
                throw NateError.message("恢复正文超过单文档 1 GB 或工作区 2 GB 预算。")
            }
            total += count
        }
        return hasCompleteSelections
    }
}
