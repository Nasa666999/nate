import Foundation

public struct EditorThemeEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let definition: EditorThemeDefinition
    public let sourcePath: String?
    public let watchesSource: Bool

    /// 业务作用：主题库以稳定身份保存定义和明确的本地热更新来源，不让名称变化重定向应用目标。
    /// 参数说明:
    /// - id: 当前主题的稳定唯一身份。
    /// - definition: 全部字段已经校验的完整定义。
    /// - sourcePath: 用户明确导入的本地绝对路径，为空时没有外部来源。
    /// - watchesSource: 是否明确允许读取该来源的新内容。
    /// 返回：来源字段合法的独立主题项；相对路径、NUL 或无来源监视整体拒绝。
    public init(
        id: UUID = UUID(),
        definition: EditorThemeDefinition,
        sourcePath: String? = nil,
        watchesSource: Bool = false
    ) throws {
        if let sourcePath {
            guard sourcePath.hasPrefix("/"), sourcePath.utf8.count <= 4096,
                !sourcePath.utf8.contains(0)
            else {
                throw NateError.message("主题来源须为至多 4096 UTF-8 字节且不含 NUL 的本地绝对路径。")
            }
        }
        guard !watchesSource || sourcePath != nil else {
            throw NateError.message("没有明确本地来源的主题不能启用热更新。")
        }
        self.id = id
        self.definition = definition
        self.sourcePath = sourcePath
        self.watchesSource = watchesSource
    }

    /// 业务作用：主题项恢复前复验完整字段，未知来源设置不能在启动后隐式取得监视权限。
    /// 参数说明:
    /// - decoder: 所属主题库的受限解码器。
    /// 返回：已知字段及合法本地来源全部确认后恢复，否则拒绝主题库。
    public init(from decoder: Decoder) throws {
        try EditorThemeCodingKey.validate(
            decoder,
            allowed: ["id", "definition", "sourcePath", "watchesSource"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            definition: values.decode(EditorThemeDefinition.self, forKey: .definition),
            sourcePath: values.decodeIfPresent(String.self, forKey: .sourcePath),
            watchesSource: values.decode(Bool.self, forKey: .watchesSource)
        )
    }
}

public struct EditorThemeLibrary: Codable, Sendable, Equatable {
    public let format: Int
    public let entries: [EditorThemeEntry]
    public let selectedID: UUID?

    /// 业务作用：主题库整体确认唯一身份、名称、选择和共同容量，不能把部分可读主题替换为当前配置。
    /// 参数说明:
    /// - entries: 最多三十二项完整主题及明确本地来源。
    /// - selectedID: 当前明确选择；为空表示沿用系统及原资源样式。
    /// 返回：所有主题不冲突且总计不超过 16384 个样式和 8 MiB 原字段时建立，否则整体拒绝。
    public init(entries: [EditorThemeEntry] = [], selectedID: UUID? = nil) throws {
        guard entries.count <= 32 else {
            throw NateError.message("主题库最多保留三十二项完整主题。")
        }
        var identities: Set<UUID> = [], names: Set<String> = []
        var remaining = 8 * 1024 * 1024, count = 0
        for entry in entries {
            guard identities.insert(entry.id).inserted,
                names.insert(entry.definition.name).inserted
            else {
                throw NateError.message("主题库包含重复身份或主题名称，未采用部分内容。")
            }
            let theme = entry.definition
            var fields = [theme.name, entry.sourcePath ?? ""]
            for (role, color) in theme.colors {
                fields.append(role)
                fields.append(color)
            }
            var groups = Array(theme.languageStyles.values)
            groups.append(theme.kindStyles)
            fields.append(contentsOf: theme.languageStyles.keys)
            for group in groups {
                guard group.count <= 16_384 - count else {
                    throw NateError.message("主题库的全部样式超过 16384 项。")
                }
                count += group.count
                for (key, style) in group {
                    fields.append(contentsOf: [
                        key, style.foreground ?? "", style.background ?? "", style.fontName ?? "",
                    ])
                }
            }
            for field in fields {
                guard field.utf8.count <= remaining else {
                    throw NateError.message("主题库有效原字段超过 8 MiB。")
                }
                remaining -= field.utf8.count
            }
        }
        if let selectedID, !identities.contains(selectedID) {
            throw NateError.message("主题库的当前选择没有对应完整主题。")
        }
        format = 1
        self.entries = entries
        self.selectedID = selectedID
    }

    /// 业务作用：主题库恢复只接受已知完整格式，当前选择不能引用缺失项。
    /// 参数说明:
    /// - decoder: 已通过文件容量与唯一键门禁的解码器。
    /// 返回：完整主题库全部合法时恢复，否则保留原归档并由调用方采用安全显示。
    public init(from decoder: Decoder) throws {
        try EditorThemeCodingKey.validate(decoder, allowed: ["format", "entries", "selectedID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .format) == 1 else {
            throw NateError.message("主题库归档格式无法识别。")
        }
        try self.init(
            entries: values.decode([EditorThemeEntry].self, forKey: .entries),
            selectedID: values.decodeIfPresent(UUID.self, forKey: .selectedID)
        )
    }

    /// 业务作用：主题偏好归档在解码前执行共同容量及唯一键检查，损坏配置不能触发任何外部读取。
    /// 参数说明:
    /// - data: 最多 16 MiB 的完整主题库 JSON。
    /// - permit: 当前偏好来源及操作生命周期仍有效。
    /// 返回：完整合法主题库；取消、未知字段、重复或超量整体拒绝。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> EditorThemeLibrary {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < deadline
        }
        try ConfigurationJSONInput.validate(
            data,
            maximumBytes: 16 * 1024 * 1024,
            maximumKeys: 131_072,
            label: "主题库",
            permit: allowed
        )
        let value = try JSONDecoder().decode(Self.self, from: data)
        try Task.checkCancellation()
        guard allowed() else {
            throw NateError.message("主题库来源资格已改变或超过共同截止。")
        }
        return value
    }

    /// 业务作用：主题库偏好完整编码后才允许写入，超量不能覆盖已有有效归档。
    /// 参数说明:
    /// - permit: 当前来源与应用意图仍有效。
    /// 返回：最多 16 MiB 的完整稳定 JSON；失去资格或取消时拒绝发布。
    public func encoded(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try Task.checkCancellation()
        guard permit() else {
            throw NateError.message("主题库保存资格已经改变。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try Task.checkCancellation()
        guard data.count <= 16 * 1024 * 1024, permit(), ContinuousClock.now < deadline else {
            throw NateError.message("主题库归档超量、超时或来源已改变，原配置保留。")
        }
        return data
    }
}
