import Foundation
import NateCore

private struct RecoveryImportCapacity: Error, LocalizedError {
    var errorDescription: String? {
        "所选完整工作区超过当前剩余的正文容量或文档数量，未改用更早记录或导入部分内容。"
    }
}

extension RecoveryStore {
    /// 业务作用：先预检完整清单容量，再逐块核验并构建正文树，当前记录损坏时回退上一有效索引。
    /// 参数说明:
    /// - maximumWorkspaceBytes: 调用方当前可接收的正文总字节数，不能超过恢复预算。
    /// - maximumDocuments: 调用方当前可接收的文档数，不能超过恢复数量上限。
    /// - permit: 当前读取仍有效的执行资格。
    /// 返回：有界工作区的完整正文树与活动身份；调用方剩余容量不足时直接拒绝，不回退到更早记录。
    public func restoreSnapshots(
        maximumWorkspaceBytes: Int = RecoveryLimits.workspaceBytes,
        maximumDocuments: Int = RecoveryLimits.documents,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> (documents: [RecoveredSnapshot], active: UUID?) {
        guard (0...RecoveryLimits.workspaceBytes).contains(maximumWorkspaceBytes),
            (0...RecoveryLimits.documents).contains(maximumDocuments)
        else {
            throw RecoveryImportCapacity()
        }
        let deadline = ContinuousClock.now.advanced(by: RecoveryLimits.processingTime)
        var lastError: (any Error)?
        var found = false
        for filename in ["session.json", "session.previous.json"] {
            let url = directory.appendingPathComponent(filename)
            do {
                try checkRecoveryBudget(deadline, permit: permit)
                guard try recoveryFileExists(url) else {
                    continue
                }
                found = true
                let index = try readRecoveryIndex(url).index
                guard index.documents.count <= maximumDocuments else {
                    throw RecoveryImportCapacity()
                }
                var total = 0
                // 在分配任何新正文树之前检查整份清单，不能先装入数个大文档才发现总预算超限。
                for reference in index.documents {
                    try checkRecoveryBudget(deadline, permit: permit)
                    let count = try recoveryByteCount(reference, permit: permit)
                    guard count <= RecoveryLimits.workspaceBytes - total else {
                        throw NateError.message("工作区正文超过恢复载入的 2 GB 预算，现有记录全部保留。")
                    }
                    guard count <= maximumWorkspaceBytes - total else {
                        throw RecoveryImportCapacity()
                    }
                    total += count
                }
                total = 0
                var documents: [RecoveredSnapshot] = []
                for reference in index.documents {
                    let recovered = try loadSnapshot(
                        reference,
                        maximumBytes: maximumWorkspaceBytes - total,
                        deadline: deadline,
                        permit: permit
                    )
                    // 先检查累计规模再把新文档加入恢复集合，超限不能以部分载入冒充完整工作区。
                    guard recovered.text.byteCount <= RecoveryLimits.workspaceBytes - total else {
                        throw NateError.message("工作区正文超过恢复载入的 2 GB 预算，现有记录全部保留。")
                    }
                    total += recovered.text.byteCount
                    documents.append(recovered)
                }
                try checkRecoveryBudget(deadline, permit: permit)
                return (documents, index.active)
            }
            catch is RecoveryImportCapacity {
                // 读取资格不足不能通过选择更早且更小的快照改变用户明确选择的完整工作区。
                throw RecoveryImportCapacity()
            }
            catch is CancellationError {
                throw CancellationError()
            }
            catch {
                found = true
                lastError = error
            }
        }
        if found, let lastError {
            throw lastError
        }
        return ([], nil)
    }

    /// 业务作用：按内容片段验证并恢复一个文档，不为应用编辑路径分配整篇中间 String。
    /// 参数说明:
    /// - reference: 工作区或关闭归档持有的快照证据。
    /// - maximumBytes: 当前工作区剩余正文预算。
    /// - deadline: 整个恢复动作的单调处理截止时间。
    /// - permit: 当前完整读取仍有效的执行资格。
    /// 返回：完整正文树与轻量元数据；缺块、非法 UTF-8 或校验失败时抛错。
    func loadSnapshot(
        _ reference: RecoveryReference,
        maximumBytes: Int = RecoveryLimits.documentBytes,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws
        -> RecoveredSnapshot
    {
        let deadline = deadline ?? .now.advanced(by: RecoveryLimits.processingTime)
        try checkRecoveryBudget(deadline, permit: permit)
        if reference.file.hasSuffix(".json") {
            let data = try readSnapshotData(reference, permit: permit)
            var record = try JSONDecoder().decode(RecoveryDocument.self, from: data)
            guard record.id == reference.id,
                record.text.utf8.count <= min(maximumBytes, RecoveryLimits.documentBytes)
            else {
                throw NateError.message("恢复文档身份或正文大小不符合记录。")
            }
            let tree = PieceTree(record.text)
            record.text = ""
            return RecoveredSnapshot(metadata: record, text: tree, reference: reference)
        }
        let manifest = try readManifest(reference, permit: permit)
        guard manifest.byteCount <= maximumBytes else {
            throw NateError.message("恢复文档超过工作区剩余正文预算，现有记录已保留。")
        }
        var trees: [PieceTree] = []
        var decoded: [String: PieceTree] = [:]
        for chunk in manifest.chunks {
            try checkRecoveryBudget(deadline, permit: permit)
            if let cached = decoded[chunk.checksum] {
                guard cached.byteCount == chunk.byteCount, cached.utf16Count == chunk.utf16Count else {
                    throw NateError.message("共享恢复分块的长度声明不一致。")
                }
                trees.append(cached)
                continue
            }
            let data = try readChunk(chunk, permit: permit)
            guard let text = String(data: data, encoding: .utf8), text.utf16.count == chunk.utf16Count else {
                throw NateError.message("恢复分块包含非法 UTF-8 或长度不符，现有记录已保留。")
            }
            let tree = PieceTree(text)
            decoded[chunk.checksum] = tree
            trees.append(tree)
        }
        let text = PieceTree.joining(trees)
        guard text.byteCount == manifest.byteCount, text.utf16Count == manifest.utf16Count else {
            throw NateError.message("恢复正文总长度不符合清单。")
        }
        return RecoveredSnapshot(metadata: manifest.metadata, text: text, reference: reference)
    }

    /// 业务作用：恢复前只读取声明和必要的旧式正文长度，先阻止超出工作区预算的分配。
    /// 参数说明:
    /// - reference: 需要估算正文规模的已校验记录引用。
    /// - permit: 当前读取仍有效的执行资格。
    /// 返回：不超过单文档预算的实际或清单声明字节数。
    private func recoveryByteCount(_ reference: RecoveryReference, permit: @Sendable () -> Bool) throws -> Int
    {
        if reference.file.hasSuffix(".snapshot") {
            return try readManifest(reference, permit: permit).byteCount
        }
        let record = try JSONDecoder().decode(
            RecoveryDocument.self,
            from: readSnapshotData(reference, permit: permit)
        )
        guard record.id == reference.id, record.text.utf8.count <= RecoveryLimits.documentBytes else {
            throw NateError.message("恢复正文大小或身份不符合记录。")
        }
        return record.text.utf8.count
    }

    /// 业务作用：解析有界索引并拒绝重复身份、未知格式与失效活动标签。
    /// 参数说明:
    /// - url: 当前或上一份工作区索引。
    /// 返回：已验证索引与同次原始字节基线，供后续安全发布使用。
    func readRecoveryIndex(_ url: URL) throws -> (index: RecoveryIndex, bytes: FileReadEvidence) {
        let bytes = try readRecoveryFile(url, maximumBytes: RecoveryLimits.metadataBytes)
        let index = try JSONDecoder().decode(RecoveryIndex.self, from: bytes.data)
        guard index.format == 1 || index.format == 2,
            index.documents.count <= RecoveryLimits.documents,
            Set(index.documents.map(\.id)).count == index.documents.count,
            index.active == nil
                || index.documents.contains(where: {
                    $0.id == index.active
                })
        else {
            throw NateError.message("恢复索引格式、身份或数量超出支持范围，现有记录已保留。")
        }
        return (index, bytes)
    }

    /// 业务作用：检查清单自身及有序内容根，再允许读取或标记其依赖。
    /// 参数说明:
    /// - reference: 清单文件和完整性证据。
    /// - permit: 当前读取仍有效的执行资格。
    /// 返回：已验证元数据、内容长度与分块清单。
    func readManifest(
        _ reference: RecoveryReference,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> RecoveryManifest {
        let manifest = try JSONDecoder().decode(
            RecoveryManifest.self,
            from: readSnapshotData(reference, permit: permit)
        )
        guard manifest.format == 2, manifest.metadata.id == reference.id, manifest.metadata.text.isEmpty,
            manifest.byteCount >= 0, manifest.byteCount <= RecoveryLimits.documentBytes,
            manifest.utf16Count >= 0, manifest.utf16Count <= manifest.byteCount,
            manifest.chunks.count <= RecoveryLimits.chunksPerDocument
        else {
            throw NateError.message("恢复清单格式、文档身份或正文预算不符合要求。")
        }
        var count = 0
        var utf16 = 0
        for chunk in manifest.chunks {
            try validateChunk(chunk)
            guard chunk.byteCount <= RecoveryLimits.documentBytes - count else {
                throw NateError.message("恢复内容长度超出预算。")
            }
            count += chunk.byteCount
            utf16 += chunk.utf16Count
        }
        guard count == manifest.byteCount, utf16 == manifest.utf16Count,
            try chunkRoot(manifest.chunks) == manifest.contentRoot
        else {
            throw NateError.message("恢复清单的有序内容完整性校验失败。")
        }
        return manifest
    }

    /// 业务作用：读取独立记录前验证路径和摘要，清单元数据与旧式正文分别受大小预算限制。
    /// 参数说明:
    /// - reference: 可靠索引中的记录引用。
    /// - permit: 当前读取仍有效的执行资格。
    /// 返回：同一次读取中通过 SHA-256 核验的完整记录。
    func readSnapshotData(
        _ reference: RecoveryReference,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        try validateReference(reference)
        let limit =
            reference.file.hasSuffix(".snapshot")
            ? RecoveryLimits.metadataBytes : RecoveryLimits.documentBytes
        let data = try readRecoveryFile(
            directory.appendingPathComponent(reference.file),
            maximumBytes: limit,
            permit: permit
        ).data
        guard FileStorage.digest(data) == reference.checksum else {
            throw NateError.message("恢复记录完整性校验失败，现有文件已保留。")
        }
        return data
    }

    /// 业务作用：私有恢复文件名只能引用指定文档的一份独立记录，不能越出恢复目录。
    /// 参数说明:
    /// - reference: 待验证的记录身份、路径和摘要。
    /// 返回：文件名结构和摘要合法时继续，否则拒绝访问。
    func validateReference(_ reference: RecoveryReference) throws {
        guard validChecksum(reference.checksum),
            isRecoveryRecordFilename(reference.file, id: reference.id, checksum: reference.checksum)
        else {
            throw NateError.message("恢复引用不是合法的文档记录路径。")
        }
    }

    /// 业务作用：只识别恢复记录自身的精确命名，内容地址清单同时验证文件名与索引摘要一致。
    /// 参数说明:
    /// - name: 当前目录中的文件名，不能含父路径。
    /// - id: 有索引引用时必须匹配的文档身份。
    /// - checksum: 内容地址清单必须匹配的摘要；清理无引用候选时可为空。
    /// 返回：兼容独立 UUID 记录与内容地址清单，其它命名不作为恢复材料访问或清理。
    func isRecoveryRecordFilename(_ name: String, id: UUID? = nil, checksum: String? = nil) -> Bool {
        let path = name as NSString
        let ext = path.pathExtension
        let base = path.deletingPathExtension
        guard ext == "json" || ext == "snapshot", base.count == 73 || base.count == 101,
            let documentID = UUID(uuidString: String(base.prefix(36))), id == nil || documentID == id,
            base[base.index(base.startIndex, offsetBy: 36)] == "-"
        else {
            return false
        }
        let suffix = String(base.dropFirst(37))
        if base.count == 73 {
            return UUID(uuidString: suffix) != nil
        }
        return ext == "snapshot" && validChecksum(suffix) && (checksum == nil || checksum == suffix)
    }

    /// 业务作用：内容地址只允许固定长度十六进制摘要和有界非空长度。
    /// 参数说明:
    /// - chunk: 单个正文依赖。
    /// 返回：合法依赖可参与读取或清理标记，否则保留现场并抛错。
    func validateChunk(_ chunk: RecoveryChunkReference) throws {
        guard validChecksum(chunk.checksum), chunk.byteCount > 0,
            chunk.byteCount <= RecoveryLimits.chunkBytes, chunk.utf16Count > 0,
            chunk.utf16Count <= chunk.byteCount
        else {
            throw NateError.message("恢复分块地址或长度不合法。")
        }
    }

    /// 业务作用：验证完整内容分块，不使用替代字符掩盖截断或改写。
    /// 参数说明:
    /// - chunk: 已声明的内容摘要与长度。
    /// - permit: 当前读取仍有效的执行资格。
    /// 返回：原始 UTF-8 字节；内容或长度不一致时失败。
    func readChunk(
        _ chunk: RecoveryChunkReference,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        try validateChunk(chunk)
        let data = try readRecoveryFile(
            chunksDirectory.appendingPathComponent(chunk.checksum + ".chunk"),
            maximumBytes: RecoveryLimits.chunkBytes,
            permit: permit
        ).data
        guard data.count == chunk.byteCount, FileStorage.digest(data) == chunk.checksum else {
            throw NateError.message("恢复分块缺失或完整性校验失败。")
        }
        return data
    }

    /// 业务作用：内容地址采用规范的小写 SHA-256，不能被路径分隔符或不完整摘要冒用。
    /// 参数说明:
    /// - value: 待使用的摘要文本。
    /// 返回：恰好 64 个小写十六进制字节时为真。
    func validChecksum(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
