import Foundation
import NateCore

extension RecoveryStore {
    /// 业务作用：先校验并标记两份工作区索引和关闭归档的完整依赖，之后才清理精确未引用路径。
    /// 参数说明:
    /// - retention: 无索引引用的额外保留时间，单位为秒。
    /// 返回：仅本恢复目录内过期记录与分块被移除；任何依赖不可识别时停止清理。
    public func collect(retention: TimeInterval = 7 * 86_400) throws {
        let deadline = storageBudget?.deadline ?? .now.advanced(by: RecoveryLimits.processingTime)
        // 清理与准备快照共用目录资格，尚未发布的新分块不能在写入途中被误当成无引用内容删除。
        let lease: RecoveryStorageLease?
        if storageBudget?.allowed == true {
            lease = nil
        }
        else {
            lease = try RecoveryStorageLease(directory: directory, deadline: deadline)
        }
        defer {
            lease?.release()
        }
        progress(.collecting)
        let hasChunks = try recoveryChunksExist()
        var references = try archivedReferences()
        for name in ["session.json", "session.previous.json"] {
            let url = directory.appendingPathComponent(name)
            if try recoveryFileExists(url) {
                references.append(contentsOf: try readRecoveryIndex(url).index.documents)
            }
        }
        var records: Set<String> = []
        var checksums: [String: String] = [:]
        var chunks: [String: RecoveryChunkReference] = [:]
        for reference in references {
            try checkRecoveryBudget(
                deadline,
                permit: {
                    true
                }
            )
            try validateReference(reference)
            if let checksum = checksums[reference.file], checksum != reference.checksum {
                throw NateError.message("同一恢复记录存在不一致的完整性声明，停止清理。")
            }
            checksums[reference.file] = reference.checksum
            guard records.insert(reference.file).inserted else {
                continue
            }
            if reference.file.hasSuffix(".snapshot") {
                for chunk in try readManifest(reference).chunks {
                    if let existing = chunks[chunk.checksum],
                        existing.byteCount != chunk.byteCount || existing.utf16Count != chunk.utf16Count
                    {
                        throw NateError.message("恢复分块存在不一致的长度声明，停止清理。")
                    }
                    chunks[chunk.checksum] = chunk
                    guard chunks.count <= RecoveryLimits.collectionChunks else {
                        throw NateError.message("恢复依赖数量超过清理预算，停止清理并保留全部材料。")
                    }
                }
            }
            else {
                // 旧记录没有分块依赖，仍核验其证据，不能因引用可解码就删除其它恢复材料。
                let proof = try readRecoveryFile(
                    directory.appendingPathComponent(reference.file),
                    maximumBytes: RecoveryLimits.documentBytes,
                    collectBytes: false
                ).baseline
                guard proof.digest == reference.checksum else {
                    throw NateError.message("恢复记录校验失败，停止清理并保留全部内容。")
                }
            }
        }
        for chunk in chunks.values {
            try checkRecoveryBudget(
                deadline,
                permit: {
                    true
                }
            )
            let data = try readChunk(chunk)
            guard let text = UTF8Text.decode(data), text.utf16.count == chunk.utf16Count else {
                throw NateError.message("恢复内容不是长度一致的合法 UTF-8，停止清理。")
            }
        }
        // 依赖验证全部完成后才开始删除，缺块、未知格式或损坏索引不会触发半次清理。
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        for url in files {
            try checkRecoveryBudget(
                deadline,
                permit: {
                    true
                }
            )
            let name = url.lastPathComponent
            guard !records.contains(name), isRecoveryRecordFilename(name),
                try expiredRecoveryFile(url, retention: retention)
            else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
        guard hasChunks else {
            return
        }
        for url in try FileManager.default.contentsOfDirectory(
            at: chunksDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) {
            try checkRecoveryBudget(
                deadline,
                permit: {
                    true
                }
            )
            let checksum = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "chunk", validChecksum(checksum), chunks[checksum] == nil,
                try expiredRecoveryFile(url, retention: retention)
            else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 业务作用：清理只针对当前目录中明确的普通过期文件，不跟随符号链接或处理未知条目。
    /// 参数说明:
    /// - url: 已确认命名规则的单个候选文件。
    /// - retention: 无引用后的额外保留时间。
    /// 返回：普通文件超过保留期时为真；其它条目保持原状。
    private func expiredRecoveryFile(_ url: URL, retention: TimeInterval) throws -> Bool {
        _ = try recoveryParent(url)
        let properties = try url.resourceValues(forKeys: [
            .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
            let date = properties.contentModificationDate
        else {
            return false
        }
        return Date().timeIntervalSince(date) > max(0, retention)
    }
}
