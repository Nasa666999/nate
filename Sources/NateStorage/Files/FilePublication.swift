import Foundation

public enum FileSaveStage: Sendable, Equatable {
    case preparingBytes
    case waitingForAccess
    case checkingBaseline
    case writingTemporary
    case preservingMetadata
    case synchronizingFile
    case revalidatingBaseline
    case publishing
    case published
    case synchronizingDirectory
    case confirmingSavedFile
}

public protocol FilePublicationAuthority: Sendable {
    /// 业务作用：以单次动作权限取得发布权，取消与进入不可撤销步骤必须有确定先后。
    /// 参数说明:
    /// - operation: 取得发布权后同步执行的原子文件动作。
    /// 返回：真实动作结果；撤销或重复使用的权限在动作前拒绝。
    func publish(_ operation: () throws -> Void) throws
}

public typealias FileSaveObservation = @Sendable (FileSaveStage) -> Void
