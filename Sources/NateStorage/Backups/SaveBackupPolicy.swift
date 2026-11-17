import Foundation
import NateCore

public enum SaveBackupMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case previous
    case history
}

public struct SaveBackupPolicy: Codable, Sendable, Equatable {
    public var mode: SaveBackupMode
    public var versionsPerFile: Int
    public var retentionDays: Int
    public var maximumBytes: Int64

    /// 业务作用：分别配置覆盖前备份和自动恢复，容量只统计去重后的受管理原始字节。
    /// 参数说明:
    /// - mode: 关闭、上一份或多份内容。
    /// - versionsPerFile: 多份模式每个真实路径最多保留的不同内容数。
    /// - retentionDays: 后续保存时清理超过此天数的历史内容。
    /// - maximumBytes: 全部保留内容的去重字节上限。
    /// 返回：策略值；实际使用前严格校验范围，不自动改写非法配置。
    public init(
        mode: SaveBackupMode = .disabled,
        versionsPerFile: Int = 20,
        retentionDays: Int = 30,
        maximumBytes: Int64 = 1_073_741_824
    ) {
        self.mode = mode
        self.versionsPerFile = versionsPerFile
        self.retentionDays = retentionDays
        self.maximumBytes = maximumBytes
    }

    /// 业务作用：在任何备份副作用之前拒绝不可解释的保留范围。
    /// 参数说明: 无。
    /// 返回：数量、期限和容量有效时继续；失败不删除历史或覆盖原文件。
    public func validate() throws {
        guard (1...1000).contains(versionsPerFile), (1...3650).contains(retentionDays),
            (1...1_099_511_627_776).contains(maximumBytes)
        else {
            throw NateError.message("保存备份设置超出范围：每文件 1–1000 份、1–3650 天、容量最多 1 TB。")
        }
    }
}

public struct SavedFileBackup: Codable, Sendable, Equatable, Identifiable {
    public let targetKey: String
    public let originalPath: String
    public let checksum: String
    public let byteCount: Int64
    public let created: Date
    /// 业务作用：相同真实路径和原字节共享历史身份，路径摘要按 UTF-8 原字节区分名称。
    /// 参数说明: 无。
    /// 返回：不依赖显示名称或时间排序的固定历史身份。
    public var id: String {
        targetKey + checksum
    }
}

struct SaveBackupIndex: Codable {
    var format = 1
    var entries: [SavedFileBackup]
}

public struct SaveBackupRequest: Sendable {
    let store: SaveBackupStore
    let policy: SaveBackupPolicy
    let authority: any FilePublicationScope

    /// 业务作用：把一次保存固定到当时的备份配置和可撤销的复合动作范围。
    /// 参数说明:
    /// - store: 私有原字节备份存储。
    /// - policy: 本次保存采用的策略快照。
    /// - authority: 原保存请求派生的发布权限范围。
    /// 返回：不会随设置界面后续变化而改变的备份请求。
    public init(store: SaveBackupStore, policy: SaveBackupPolicy, authority: any FilePublicationScope) {
        self.store = store
        self.policy = policy
        self.authority = authority
    }
}
