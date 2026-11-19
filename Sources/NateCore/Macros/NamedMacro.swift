import Foundation

public struct MacroShortcut: Sendable, Codable, Hashable {
    public let key: String
    public let modifiers: UInt8

    /// 业务作用：宏快捷键使用单个实际键和明确修饰键，不让普通输入字符变成隐式播放命令。
    /// 参数说明:
    /// - key: 单个 Unicode 标量对应的原生菜单键。
    /// - modifiers: Command、Option、Control、Shift 分别使用位 1、2、4、8。
    /// 返回：带 Command、Option 或 Control 的组合，或 F1 至 F35；字母使用菜单键的小写身份，其它单键、控制字符或未知位拒绝。
    public init(key: String, modifiers: UInt8) throws {
        guard key.utf8.count <= 4 else {
            throw NateError.message("宏快捷键不是单个实际键。")
        }
        let normalized = key.lowercased()
        guard normalized.unicodeScalars.count == 1, let scalar = normalized.unicodeScalars.first,
            scalar.value >= 32, scalar.value != 127, modifiers <= 15,
            modifiers & 7 != 0 || (0xF704...0xF726).contains(scalar.value)
        else {
            throw NateError.message("宏快捷键需要单个键与 Command、Option 或 Control；功能键可单独使用。")
        }
        self.key = normalized
        self.modifiers = modifiers
    }

    /// 业务作用：恢复快捷键仍沿同一按键门禁，文件字段不能截获普通文字输入。
    /// 参数说明:
    /// - decoder: 所属配置提供的有界解码器。
    /// 返回：完整合法的快捷键；未知位或非法键拒绝。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: values.decode(String.self, forKey: .key),
            modifiers: values.decode(UInt8.self, forKey: .modifiers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiers
    }
}

public struct NamedMacro: Sendable {
    public let id: UUID
    public let name: String
    public let actions: [MacroAction]
    public let archive: Data
    public let shortcut: MacroShortcut?
    public let retainedBytes: Int

    /// 业务作用：保存命名宏时固定完整语义动作和稳定身份，名称或快捷键不承担执行权限。
    /// 参数说明:
    /// - id: 本宏在菜单、列表和持久化中使用的稳定身份。
    /// - name: 一至 128 个 Unicode 标量、最多 512 字节且不含控制字符的名称。
    /// - actions: 已明确录制或导入的完整动作，至少一项。
    /// - shortcut: 可选的明确播放快捷键。
    /// 返回：可独立持久化的宏；名称、动作或归档容量无效时失败。
    public init(id: UUID = UUID(), name: String, actions: [MacroAction], shortcut: MacroShortcut? = nil)
        throws
    {
        try Self.validateName(name)
        guard !actions.isEmpty else {
            throw NateError.message("空动作列表不能保存为命名宏。")
        }
        self.id = id
        self.name = name
        self.actions = actions
        archive = try MacroArchive.encode(actions)
        self.shortcut = shortcut
        retainedBytes = Self.footprint(actions, archiveBytes: archive.count, nameBytes: name.utf8.count)
    }

    /// 业务作用：宏库中的每份受支持归档完整验证后才成为可播放定义，二进制与既有 JSON 均原样保留。
    /// 参数说明:
    /// - id: 库内稳定身份。
    /// - name: 已保存名称。
    /// - archive: 当前二进制格式或受支持的旧式 JSON 完整宏。
    /// - shortcut: 可选的明确快捷键。
    /// - permit: 所属宏库仍有完整载入资格。
    /// 返回：动作、摘要和名称均合法的定义；失败不返回部分动作。
    public init(
        id: UUID,
        name: String,
        archive: Data,
        shortcut: MacroShortcut?,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Self.validateName(name)
        let actions = try MacroArchive.decode(archive, permit: permit)
        guard !actions.isEmpty else {
            throw NateError.message("命名宏缺少实际动作。")
        }
        self.id = id
        self.name = name
        self.actions = actions
        self.archive = archive
        self.shortcut = shortcut
        retainedBytes = Self.footprint(actions, archiveBytes: archive.count, nameBytes: name.utf8.count)
    }

    /// 业务作用：重命名或分配快捷键只改变宏元数据，不重建或改变已经校验的动作字节。
    /// 参数说明:
    /// - name: 新名称。
    /// - shortcut: 新快捷键，空值表示解除绑定。
    /// 返回：保持原稳定身份与动作的完整定义；非法名称失败。
    public func updating(name: String, shortcut: MacroShortcut?) throws -> NamedMacro {
        try NamedMacro(copying: self, name: name, shortcut: shortcut)
    }

    /// 业务作用：元数据改变复用已验证归档，避免界面重命名时同步编码大批动作。
    /// 参数说明:
    /// - original: 已完整验证的原宏。
    /// - name: 新名称。
    /// - shortcut: 新快捷键。
    /// 返回：元数据合法的新定义，动作和归档保持原值。
    private init(copying original: NamedMacro, name: String, shortcut: MacroShortcut?) throws {
        try Self.validateName(name)
        id = original.id
        self.name = name
        actions = original.actions
        archive = original.archive
        self.shortcut = shortcut
        retainedBytes = original.retainedBytes - original.name.utf8.count + name.utf8.count
    }

    /// 业务作用：名称只表示可辨认的用户命令，不能用控制字符或不可见空白建立另一个同名菜单项。
    /// 参数说明:
    /// - name: 即将显示和持久化的原始名称。
    /// 返回：长度、内容与边界空白均合法时继续。
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 512, name.unicodeScalars.count <= 128,
            !name.unicodeScalars.contains(where: {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }),
            name.utf8.elementsEqual(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        else {
            throw NateError.message("宏名称需要一至 128 个字符，不能包含控制字符或两端空白。")
        }
    }

    /// 业务作用：宏库容量包含已解析动作和归档，密集空动作或片段索引不能只按小文件大小无限保留。
    /// 参数说明:
    /// - actions: 已验证的语义动作。
    /// - archiveBytes: 对应完整归档字节数。
    /// - nameBytes: 名称字节数。
    /// 返回：包含原文、载荷索引和编码的估计保留容量。
    private static func footprint(_ actions: [MacroAction], archiveBytes: Int, nameBytes: Int) -> Int {
        var bytes = archiveBytes + nameBytes + actions.count * MemoryLayout<MacroAction>.stride + 128
        for action in actions {
            switch action {
            case .input(let text), .command(let text): bytes += text.utf8.count
            case .editor, .clipboardCopy: break
            case .search(let action):
                bytes += action.options.query.utf8.count + action.options.replacement.utf8.count
            case .lineSort(let options): bytes += options.localeIdentifier.utf8.count
            case .clipboard(let payload, _):
                bytes +=
                    payload.fragments.count
                    * (MemoryLayout<ClipboardFragment>.stride + MemoryLayout<Int>.stride)
                bytes += payload.fragments.reduce(0) {
                    $0 + $1.text.utf8.count
                }
            }
        }
        return bytes
    }
}

public struct MacroLibrarySnapshot: Sendable {
    public static let maximumDefinitions = 1000
    public static let maximumRetainedBytes = 64 * 1024 * 1024
    public let definitions: [NamedMacro]

    /// 业务作用：完整宏库使用唯一身份、名称和快捷键，冲突不能靠菜单顺序决定执行哪一份内容。
    /// 参数说明:
    /// - definitions: 用户明确保留的完整宏，按列表顺序保存。
    /// 返回：最多一千份且估计保留容量不超过 64 MiB 的库；重复或超量时整体失败。
    public init(_ definitions: [NamedMacro]) throws {
        guard definitions.count <= Self.maximumDefinitions,
            Set(definitions.map(\.id)).count == definitions.count,
            Set(definitions.map(\.name)).count == definitions.count
        else {
            throw NateError.message("宏库超过一千项，或包含重复身份与名称。")
        }
        let shortcuts = definitions.compactMap(\.shortcut)
        guard Set(shortcuts).count == shortcuts.count else {
            throw NateError.message("宏库包含相同快捷键，未任选一项播放。")
        }
        var bytes = 0
        for definition in definitions {
            guard definition.retainedBytes <= Self.maximumRetainedBytes - bytes else {
                throw NateError.message("宏库动作与归档的估计保留容量超过 64 MiB。")
            }
            bytes += definition.retainedBytes
        }
        self.definitions = definitions
    }
}
