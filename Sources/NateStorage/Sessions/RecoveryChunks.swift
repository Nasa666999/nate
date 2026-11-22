import Foundation
import NateCore
import os

public enum RecoveryLimits {
    public static let documentBytes = 1_073_741_824
    public static let workspaceBytes = 2_147_483_648
    public static let metadataBytes = 8_388_608
    public static let documents = 1024
    public static let chunksPerDocument = 8192
    public static let collectionChunks = 65_536
    public static let chunkBytes = 1_048_576
    public static let processingTime = Duration.seconds(30)
}

public struct RecoveredSnapshot: Sendable {
    public let metadata: RecoveryDocument
    public let text: PieceTree
    public let reference: RecoveryReference
}

struct RecoveryChunkReference: Sendable, Codable {
    let checksum: String
    let byteCount: Int
    let utf16Count: Int
}

struct RecoveryManifest: Codable {
    var format = 2
    let metadata: RecoveryDocument
    let byteCount: Int
    let utf16Count: Int
    let contentRoot: String
    let chunks: [RecoveryChunkReference]
}

private struct RecoveryCacheState {
    var entries: [UUID: RecoveryChunkReference] = [:]
    var order: [UUID] = []
}

final class RecoveryChunkCache: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: RecoveryCacheState())

    /// 业务作用：只缓存不可变文本节点的摘要元数据，不延长已关闭正文树的生命周期。
    /// 参数说明:
    /// - id: 不会因内存地址重用而混淆的节点身份。
    /// 返回：已知的内容摘要和长度；磁盘分块仍需复验。
    func get(_ id: UUID) -> RecoveryChunkReference? {
        state.withLock {
            $0.entries[id]
        }
    }

    /// 业务作用：摘要缓存受条目数约束，不能随着长期编辑不断保留节点历史。
    /// 参数说明:
    /// - value: 已验证内容的摘要与长度。
    /// - id: 对应不可变节点身份。
    /// 返回：最多保留 4096 个轻量记录，不保存正文。
    func put(_ value: RecoveryChunkReference, for id: UUID) {
        state.withLock {
            guard $0.entries[id] == nil else {
                return
            }
            $0.entries[id] = value
            $0.order.append(id)
            while $0.order.count > 4096 {
                $0.entries.removeValue(forKey: $0.order.removeFirst())
            }
        }
    }
}

extension RecoveryStore {
    var chunksDirectory: URL {
        directory.appendingPathComponent("chunks", isDirectory: true)
    }

    /// 业务作用：直接从共享正文树持久化分块，未改变的字节复用既有内容，不复制整篇 String。
    /// 参数说明:
    /// - metadata: 已固定的恢复元数据，正文由 text 提供。
    /// - text: 已提交的不可变正文树。
    /// - deadline: 整个恢复动作的单调处理截止时间。
    /// - permit: 当前请求仍可继续准备和发布快照的权限。
    /// 返回：所有分块和清单已同步后的引用；失败不发布工作区索引。
    public func checkpoint(
        metadata: RecoveryDocument,
        text: PieceTree,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> RecoveryReference {
        let deadline = min(
            deadline ?? .now.advanced(by: RecoveryLimits.processingTime),
            storageBudget?.deadline ?? .now.advanced(by: RecoveryLimits.processingTime)
        )
        guard text.byteCount <= RecoveryLimits.documentBytes else {
            throw NateError.message("文档超过恢复保护的 1 GB 预算，现有恢复记录继续保留。")
        }
        try checkRecoveryBudget(deadline, permit: permit)
        guard metadata.selections.count <= SelectionGeometries.maximumCount else {
            throw NateError.message("恢复选择超过十万项，未写入任何分块或清单。")
        }
        // 全部选择必须先与同一正文相符，不能先持久化分块再发现稳定身份或 Tab 证据属于其它内容。
        if let state = metadata.selectionState {
            guard state.selections == metadata.selections else {
                throw NateError.message("恢复选择几何与完整身份不一致，原记录保留。")
            }
            _ = try state.validated(in: text, permit: permit)
        }
        if storageBudget == nil {
            return try withStorageWrite(deadline: deadline, permit: permit) {
                store in
                try store.checkpoint(metadata: metadata, text: text, deadline: deadline, permit: permit)
            }
        }
        try prepareRecoveryDirectory()
        var chunks: [RecoveryChunkReference] = []
        try text.forEachChunk {
            chunk in
            try checkRecoveryBudget(deadline, permit: permit)
            guard chunks.count < RecoveryLimits.chunksPerDocument else {
                throw NateError.message("正文分块数量超过恢复清单预算。")
            }
            chunks.append(try persistChunk(chunk, deadline: deadline, permit: permit))
        }
        var record = metadata
        record.text = ""
        let manifest = RecoveryManifest(
            format: record.selectionState == nil ? 2 : 3,
            metadata: record,
            byteCount: text.byteCount,
            utf16Count: text.utf16Count,
            contentRoot: try chunkRoot(chunks),
            chunks: chunks
        )
        let encoder = JSONEncoder()
        // Base64 中的斜线不需要 JSON 转义，避免合法十万项身份因字节分布不同而超出清单预算。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= RecoveryLimits.metadataBytes else {
            throw NateError.message("恢复元数据超过 8 MB 预算。")
        }
        let checksum = FileStorage.digest(data)
        let filename = record.id.uuidString + "-" + checksum + ".snapshot"
        let target = directory.appendingPathComponent(filename)
        try checkRecoveryBudget(deadline, permit: permit)
        if try recoveryFileExists(target) {
            // 索引失败后的相同快照复用原清单，但文件名中的摘要不能代替实际字节证据。
            let existing = try readRecoveryFile(
                target,
                maximumBytes: RecoveryLimits.metadataBytes,
                collectBytes: false,
                permit: permit
            )
            guard existing.baseline.digest == checksum else {
                throw NateError.message("恢复清单的内容地址与实际字节不符，现有记录已保留。")
            }
        }
        else {
            // 每个内容分块先完整同步；清单可靠后才把引用交给工作区索引发布入口。
            _ = try saveRecoveryData(data, to: target, expected: nil, permit: permit)
        }
        return RecoveryReference(
            id: record.id,
            file: filename,
            checksum: checksum,
            name: record.name
        )
    }

    /// 业务作用：复用已验证的内容文件，缺失内容可以从当前快照重建，损坏内容保留并明确拒绝。
    /// 参数说明:
    /// - chunk: 不超过 1 MB 的不可变正文子树。
    /// - deadline: 本次整个检查点的处理截止时间。
    /// - permit: 当前请求权限。
    /// 返回：已落盘并通过摘要复验的内容引用。
    private func persistChunk(
        _ chunk: TextChunk,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> RecoveryChunkReference {
        var bytes: Data?
        let reference: RecoveryChunkReference
        if let cached = chunkCache.get(chunk.id) {
            reference = cached
        }
        else {
            let data = Data(chunk.bytes())
            bytes = data
            reference = RecoveryChunkReference(
                checksum: FileStorage.digest(data),
                byteCount: chunk.byteCount,
                utf16Count: chunk.utf16Count
            )
        }
        let target = chunksDirectory.appendingPathComponent(reference.checksum + ".chunk")
        if try recoveryFileExists(target) {
            // 节点摘要缓存不代表磁盘仍存在相同字节，同大小改写和外部替换仍必须被识别。
            let baseline = try readRecoveryFile(
                target,
                maximumBytes: RecoveryLimits.chunkBytes,
                collectBytes: false,
                permit: permit
            ).baseline
            guard baseline.digest == reference.checksum else {
                throw NateError.message("恢复分块完整性校验失败，现有内容已保留；未发布新的工作区索引。")
            }
        }
        else {
            try checkRecoveryBudget(deadline, permit: permit)
            let data = bytes ?? Data(chunk.bytes())
            _ = try saveRecoveryData(data, to: target, expected: nil, permit: permit)
        }
        chunkCache.put(reference, for: chunk.id)
        return reference
    }

    /// 业务作用：内容地址以有序摘要和长度构成完整性根，片段调换、截断或重复均改变证据。
    /// 参数说明:
    /// - chunks: 原文顺序排列的内容引用。
    /// 返回：规范序列化后的 SHA-256，不依赖字典键顺序。
    func chunkRoot(_ chunks: [RecoveryChunkReference]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return FileStorage.digest(try encoder.encode(chunks))
    }

    /// 业务作用：恢复处理在分块边界检查预算，不能因慢存储持续制造过时检查点。
    /// 参数说明:
    /// - deadline: 固定单调截止时间。
    /// - permit: 请求继续准备内容的权限。
    /// 返回：仍有效时继续；取消或超限时保留现有记录并抛错。
    func checkRecoveryBudget(_ deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("恢复处理超过 30 秒预算，现有索引与正文记录均保留。")
        }
    }

    /// 业务作用：恢复目录与分块目录只存放当前用户的正文，不允许内容子目录被符号链接改向。
    /// 参数说明: 无。
    /// 返回：建立私有目录，既有非目录或符号链接被拒绝。
    private func prepareRecoveryDirectory() throws {
        try FileStorage.validateFileURL(directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if try !recoveryChunksExist() {
            try FileManager.default.createDirectory(
                at: chunksDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
