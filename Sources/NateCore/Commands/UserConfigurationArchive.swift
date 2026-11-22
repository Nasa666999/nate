import Foundation

public enum UserConfigurationArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat

    /// 业务作用：未知配置协议不进入当前偏好，向用户说明原配置仍然保留。
    /// 参数说明: 无。
    /// 返回：可直接呈现的不支持格式说明。
    public var errorDescription: String? {
        "用户配置包含不受支持的格式或字段类型，原配置保留。"
    }
}

public enum UserConfigurationArchive {
    public static let maximumBytes = 4 * 1024 * 1024
    private static let magic = Data("NATECONF".utf8)

    /// 业务作用：全部用户配置按规范键序编码并附完整摘要，文件发布前即可验证容量与完整性。
    /// 参数说明:
    /// - configuration: 已完整预检的不可变字段集合。
    /// - permit: 本次编解码仍拥有执行资格，取消时不交付部分归档。
    /// 返回：至多 4 MiB 的完整归档；取消、超时或容量不足整体失败。
    public static func encode(
        _ configuration: UserConfiguration,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = UserConfigurationBudget(permit: permit)
        var writer = UserConfigurationWriter(budget: budget)
        try writer.append(magic)
        try writer.unsigned(UInt16(1))
        try writer.unsigned(UInt16(configuration.entries.count))
        for entry in configuration.entries {
            try budget.check()
            try writer.unsigned(UInt8(entry.key.utf8.count))
            try writer.append(Data(entry.key.utf8))
            switch entry.value {
            case .unset:
                try writer.unsigned(UInt8(0))
            case .boolean(let value):
                try writer.unsigned(UInt8(1))
                try writer.unsigned(UInt8(value ? 1 : 0))
            case .integer(let value):
                try writer.unsigned(UInt8(2))
                try writer.unsigned(UInt64(bitPattern: value))
            case .decimal(let value):
                try writer.unsigned(UInt8(3))
                try writer.unsigned(value.bitPattern)
            case .text(let value):
                try writer.unsigned(UInt8(4))
                try writer.unsigned(UInt32(value.utf8.count))
                try writer.append(Data(value.utf8))
            case .bytes(let value):
                try writer.unsigned(UInt8(5))
                try writer.unsigned(UInt32(value.count))
                try writer.append(value)
            }
        }
        let digest = try UserConfigurationDigest.compute(writer.data, budget: budget)
        writer.data.append(digest)
        try budget.check()
        return writer.data
    }

    /// 业务作用：只有整份摘要、规范顺序和全部类型均可解释的配置才具有应用资格。
    /// 参数说明:
    /// - data: 至多 4 MiB 的完整原始归档，允许非零起点的 Data 切片。
    /// - permit: 当前完整读取仍有执行资格。
    /// 返回：全部不可变字段；摘要、类型、容量、UTF-8、顺序、取消或截止失败均不交付子集。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> UserConfiguration {
        let budget = UserConfigurationBudget(permit: permit)
        try budget.check()
        guard (44...maximumBytes).contains(data.count), data.starts(with: magic) else {
            throw NateError.message("用户配置大小或文件头无效。")
        }
        let body = Data(data.dropLast(32))
        guard try UserConfigurationDigest.compute(body, budget: budget).elementsEqual(data.suffix(32)) else {
            throw NateError.message("用户配置摘要不一致，未采用任何条目。")
        }
        var reader = UserConfigurationReader(data: body, budget: budget)
        _ = try reader.bytes(8)
        guard try reader.unsigned(UInt16.self) == 1 else {
            throw UserConfigurationArchiveError.unsupportedFormat
        }
        let count = Int(try reader.unsigned(UInt16.self))
        guard count <= UserConfiguration.maximumEntries else {
            throw NateError.message("用户配置超过 128 项。")
        }
        var entries: [UserPreferenceEntry] = []
        var previous = ""
        for _ in 0..<count {
            let keySize = Int(try reader.unsigned(UInt8.self))
            guard (1...96).contains(keySize) else {
                throw NateError.message("用户配置键容量无效。")
            }
            let key = try reader.text(keySize)
            guard key > previous else {
                throw NateError.message("用户配置键截断、重复或不按规范顺序排列。")
            }
            previous = key
            let tag = try reader.unsigned(UInt8.self)
            let value: UserPreferenceValue
            switch tag {
            case 0: value = .unset
            case 1:
                let flag = try reader.unsigned(UInt8.self)
                guard flag <= 1 else {
                    throw UserConfigurationArchiveError.unsupportedFormat
                }
                value = .boolean(flag == 1)
            case 2:
                value = .integer(Int64(bitPattern: try reader.unsigned(UInt64.self)))
            case 3:
                value = .decimal(Double(bitPattern: try reader.unsigned(UInt64.self)))
            case 4:
                let size = Int(try reader.unsigned(UInt32.self))
                guard size <= 65_536 else {
                    throw NateError.message("用户配置文本超过 64 KiB。")
                }
                value = .text(try reader.text(size))
            case 5:
                let size = Int(try reader.unsigned(UInt32.self))
                guard size <= 1_048_576 else {
                    throw NateError.message("用户配置字节字段超过 1 MiB。")
                }
                value = .bytes(try reader.bytes(size))
            default:
                throw UserConfigurationArchiveError.unsupportedFormat
            }
            entries.append(try UserPreferenceEntry(key: key, value: value))
        }
        // 声明条目必须恰好消费全部正文，额外字段不能被忽略后作为已确认配置发布。
        guard reader.cursor == body.count else {
            throw UserConfigurationArchiveError.unsupportedFormat
        }
        let configuration = try UserConfiguration(entries: entries)
        try budget.check()
        return configuration
    }
}
