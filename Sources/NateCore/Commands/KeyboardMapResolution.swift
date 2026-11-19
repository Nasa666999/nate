import Foundation

public struct KeyboardMapConflict: Sendable, Equatable {
    public let command: String
    public let shortcut: KeyboardShortcut
    public let owner: String
}

public struct KeyboardMapResolution: Sendable {
    public let active: [String: [KeyboardShortcut]]
    public let owners: [KeyboardShortcut: String]
    public let conflicts: [KeyboardMapConflict]
    public let unavailable: [String]

    /// 业务作用：按实际命令目录解析用户覆盖，不存在的命令不取得执行权，冲突覆盖不截获仍保留的默认入口。
    /// 参数说明:
    /// - defaults: 按实际菜单优先顺序提供的完整默认命令，每项身份必须唯一。
    /// - configuration: 用户完整覆盖，空列表表示取消该命令的默认组合。
    /// - managedElsewhere: 由独立命令库管理的身份，其绑定保持来自实际定义。
    /// 返回：唯一可执行组合、逐项冲突与不可用身份；被禁用或未提供的配置保留在原映射中。
    public init(defaults: [CommandKeyBinding], configuration: KeyboardMap, managedElsewhere: Set<String> = [])
        throws
    {
        guard defaults.count <= KeyboardMap.maximumCommands else {
            throw NateError.message("当前命令目录超过两千项，未安装快捷键。")
        }
        let known = Set(defaults.map(\.command))
        guard known.count == defaults.count else {
            throw NateError.message("当前命令目录重复提供同一身份，未安装快捷键。")
        }
        let requested = Dictionary(
            uniqueKeysWithValues: configuration.overrides.map {
                ($0.command, $0.shortcuts)
            }
        )
        var owners: [KeyboardShortcut: String] = [:]
        var active: [String: [KeyboardShortcut]] = [:]
        var conflicts: [KeyboardMapConflict] = []
        for overridden in [false, true] {
            for binding in defaults {
                let usesOverride =
                    requested[binding.command] != nil && !managedElsewhere.contains(binding.command)
                guard usesOverride == overridden else {
                    continue
                }
                let shortcuts = usesOverride ? (requested[binding.command] ?? []) : binding.shortcuts
                var accepted: [KeyboardShortcut] = []
                for shortcut in shortcuts {
                    if let owner = owners[shortcut], owner != binding.command {
                        // 未改变的默认命令先保留执行权，导入的新组合不能依靠安装顺序截走已有业务动作。
                        conflicts.append(
                            KeyboardMapConflict(command: binding.command, shortcut: shortcut, owner: owner)
                        )
                    }
                    else {
                        owners[shortcut] = binding.command
                        accepted.append(shortcut)
                    }
                }
                active[binding.command] = accepted
            }
        }
        self.active = active
        self.owners = owners
        self.conflicts = conflicts
        unavailable = configuration.overrides.compactMap {
            !known.contains($0.command) || managedElsewhere.contains($0.command) ? $0.command : nil
        }
    }
}
