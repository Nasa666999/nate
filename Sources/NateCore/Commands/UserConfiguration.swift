import Foundation

public enum UserPreferenceValue: Sendable, Equatable {
    case unset
    case boolean(Bool)
    case integer(Int64)
    case decimal(Double)
    case text(String)
    case bytes(Data)

    /// 业务作用：配置字段在编码前受类型与单项容量约束，非有限数字不能进入持久化配置。
    /// 参数说明: 无。
    /// 返回：有限数字、至多 64 KiB 的原文字段或至多 1 MiB 的字节字段通过，否则整体失败。
    public func validate() throws {
        switch self {
        case .unset, .boolean, .integer:
            break
        case .decimal(let value):
            guard value.isFinite else {
                throw NateError.message("用户配置不能包含非有限数字。")
            }
        case .text(let value):
            guard value.utf8.count <= 65_536 else {
                throw NateError.message("用户配置的单项原文超过 64 KiB。")
            }
        case .bytes(let value):
            guard value.count <= 1_048_576 else {
                throw NateError.message("用户配置的单项字节超过 1 MiB。")
            }
        }
    }

    /// 业务作用：整份配置按实际字段载荷计量，不让条目数限制掩盖大字段分配。
    /// 参数说明: 无。
    /// 返回：当前值的完整载荷容量，字符串按 UTF-8 原字节计数。
    var retainedBytes: Int {
        switch self {
        case .unset: return 0
        case .boolean: return 1
        case .integer, .decimal: return 8
        case .text(let value): return value.utf8.count
        case .bytes(let value): return value.count
        }
    }

    /// 业务作用：配置原文采用字节身份，规范等价字符与带符号零不能掩盖真实归档变化。
    /// 参数说明:
    /// - lhs: 已固定的完整字段。
    /// - rhs: 需要复验的当前字段。
    /// 返回：类型和原始载荷完全一致时为真。
    public static func == (lhs: UserPreferenceValue, rhs: UserPreferenceValue) -> Bool {
        switch (lhs, rhs) {
        case (.unset, .unset): return true
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.decimal(let a), .decimal(let b)): return a.bitPattern == b.bitPattern
        case (.text(let a), .text(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.bytes(let a), .bytes(let b)): return a.elementsEqual(b)
        default: return false
        }
    }
}

public struct UserPreferenceEntry: Sendable, Equatable {
    public let key: String
    public let value: UserPreferenceValue

    /// 业务作用：完整配置条目只使用明确 ASCII 键，空键、隐藏分隔符或超长名称不能被重新解释。
    /// 参数说明:
    /// - key: 一至九十六字节的 ASCII 配置键。
    /// - value: 已分类且需要完整保存的字段值，未设置状态与显式默认值分别保留。
    /// 返回：键和值均合法的独立条目，否则整体拒绝。
    public init(key: String, value: UserPreferenceValue) throws {
        guard (1...96).contains(key.utf8.count),
            key.utf8.allSatisfy({
                $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 || $0 >= 48 && $0 <= 57
                    || [45, 46, 95].contains($0)
            })
        else {
            throw NateError.message("用户配置键须为 1–96 字节的 ASCII 字母、数字、点、下划线或连字符。")
        }
        try value.validate()
        self.key = key
        self.value = value
    }
}

public struct UserConfiguration: Sendable, Equatable {
    public static let maximumEntries = 128
    public static let maximumPayloadBytes = 4 * 1024 * 1024 - 16_384
    public let entries: [UserPreferenceEntry]

    /// 业务作用：全部用户配置先完整预检并固定规范顺序，重复键或容量不足不能产生可应用的子集。
    /// 参数说明:
    /// - entries: 至多 128 项完整配置，键不能重复。
    /// 返回：按 ASCII 键排序的不可变配置；超过总载荷或存在重复身份时整体失败。
    public init(entries: [UserPreferenceEntry]) throws {
        guard entries.count <= Self.maximumEntries else {
            throw NateError.message("用户配置超过 128 项，未采用部分条目。")
        }
        var keys: Set<String> = []
        var remaining = Self.maximumPayloadBytes
        for entry in entries {
            try entry.value.validate()
            guard keys.insert(entry.key).inserted else {
                throw NateError.message("用户配置包含重复键，未采用任何重复定义。")
            }
            let cost = entry.key.utf8.count + entry.value.retainedBytes
            guard cost <= remaining else {
                throw NateError.message("用户配置完整载荷超过容量，未采用部分条目。")
            }
            remaining -= cost
        }
        self.entries = entries.sorted {
            $0.key < $1.key
        }
    }
}
