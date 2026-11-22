import Foundation

public enum RecoveryProgress: Sendable, Equatable {
    case waitingForStorage
    case measuringStorage
    case preparingDocument(id: UUID, revision: UInt64, bytes: Int, chunks: Int)
    case verifyingChunk(
        id: UUID,
        completedBytes: Int,
        totalBytes: Int,
        completedChunks: Int,
        totalChunks: Int
    )
    case chunkConfirmed(
        id: UUID,
        completedBytes: Int,
        totalBytes: Int,
        completedChunks: Int,
        totalChunks: Int
    )
    case preparingManifest(id: UUID, revision: UInt64)
    case verifyingManifest(id: UUID, revision: UInt64)
    case writingManifest(id: UUID, revision: UInt64)
    case manifestConfirmed(id: UUID, revision: UInt64)
    case verifyingIndex(documents: Int)
    case synchronizingDependencies
    case retainingPreviousIndex
    case publishingIndex
    case indexConfirmed
    case verifyingSidebars
    case sidebarsConfirmed
    case archivingDocument(id: UUID)
    case archiveConfirmed(id: UUID)
    case collecting
    case fileStage(target: String, stage: FileSaveStage)
}

public typealias RecoveryProgressObservation = @Sendable (RecoveryProgress) -> Void

extension RecoveryStore {
    /// 业务作用：为一次恢复动作连接只读进度观察，观察数据不包含正文、文件句柄或发布权限。
    /// 参数说明:
    /// - observation: 同步接收实际阶段的轻量观察入口，不应阻塞或重入同一目录写入。
    /// 返回：共享存储与摘要缓存的新值，原存储观察入口和已经开始的动作保持独立。
    public func observingProgress(_ observation: @escaping RecoveryProgressObservation) -> RecoveryStore {
        var copy = self
        copy.progress = observation
        return copy
    }
}
