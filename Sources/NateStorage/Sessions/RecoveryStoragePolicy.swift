import Foundation
import NateCore

public enum RecoveryStoragePolicyFailure: Error, LocalizedError, Sendable {
    case invalidCapacity
    case unknownFields

    /// 业务作用：策略拒绝与实际文件失败分别反馈，明确采用合法设置后可继续原恢复候选。
    /// 参数说明: 无。
    /// 返回：非法容量或未知字段的可读原因，不授予任何文件写入权限。
    public var errorDescription: String? {
        switch self {
        case .invalidCapacity:
            return "恢复存储总量须为 1 MiB 至 1 TiB，现有恢复内容继续保留。"
        case .unknownFields:
            return "恢复存储策略字段不完整或尚不可解释。"
        }
    }
}

public struct RecoveryStoragePolicy: Codable, Sendable, Equatable {
    public var maximumBytes: Int64

    /// 业务作用：恢复容量独立于原文件和保存前备份，限制当前实例恢复目录内的逻辑文件总量。
    /// 参数说明:
    /// - maximumBytes: 全部恢复文件及写入临时内容的总字节上限，默认 8 GiB。
    /// 返回：策略值，实际写入前必须完成范围校验；降低上限不删除已有内容。
    public init(maximumBytes: Int64 = 8_589_934_592) {
        self.maximumBytes = maximumBytes
    }

    /// 业务作用：在恢复副作用前拒绝不可解释的容量，不能把非法配置当成无限制写入。
    /// 参数说明: 无。
    /// 返回：1 MiB 至 1 TiB 的完整整数容量通过，其它值抛错并保留原恢复材料。
    public func validate() throws {
        guard (1_048_576...1_099_511_627_776).contains(maximumBytes) else {
            throw RecoveryStoragePolicyFailure.invalidCapacity
        }
    }

    /// 业务作用：恢复策略只解释完整已知字段，未知约束不能被忽略后继续写入。
    /// 参数说明:
    /// - decoder: 所属配置入口已限制容量的解码器。
    /// 返回：完整合法策略；未知、缺失、错误类型或超量字段均失败。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: Int64].self)
        guard Set(values.keys) == ["maximumBytes"], let maximumBytes = values["maximumBytes"] else {
            throw RecoveryStoragePolicyFailure.unknownFields
        }
        self.maximumBytes = maximumBytes
        try validate()
    }

    /// 业务作用：完整容量策略独立编码，不包含恢复路径或任何文档内容。
    /// 参数说明:
    /// - encoder: 所属配置归档使用的编码器。
    /// 返回：仅输出已知最大字节数字段，编码失败不发布配置。
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.singleValueContainer()
        try container.encode(["maximumBytes": maximumBytes])
    }
}

public struct RecoveryStorageUsage: Sendable, Equatable {
    public let bytes: Int64
    public let files: Int
}
