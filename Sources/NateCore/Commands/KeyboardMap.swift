import Foundation

public struct CommandKeyBinding: Sendable, Equatable {
    public let command: String
    public let shortcuts: [KeyboardShortcut]

    /// 业务作用：一个命令可保留多个完整组合，空数组明确取消其默认绑定，不把命令身份解释为路径。
    /// 参数说明:
    /// - command: 当前命令目录使用的稳定身份，最多 1024 字节。
    /// - shortcuts: 本命令的完整有序组合，最多十六项且不得重复。
    /// 返回：合法的完整绑定；空身份、控制字符、重复或超量组合拒绝。
    public init(command: String, shortcuts: [KeyboardShortcut]) throws {
        guard !command.isEmpty, command.utf8.count <= KeyboardMap.maximumCommandBytes,
            command.trimmingCharacters(in: .whitespacesAndNewlines) == command,
            !command.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                    || $0.properties.generalCategory == .paragraphSeparator
            }), shortcuts.count <= KeyboardMap.maximumBindingsPerCommand,
            Set(shortcuts).count == shortcuts.count
        else {
            throw NateError.message("命令身份或快捷键数量无效，同一命令最多十六项不同绑定。")
        }
        self.command = command
        self.shortcuts = shortcuts
    }
}

public struct KeyboardMap: Sendable, Equatable {
    public static let maximumCommands = 2000
    public static let maximumCommandBytes = 1024
    public static let maximumBindingsPerCommand = 16
    public let overrides: [CommandKeyBinding]

    /// 业务作用：没有用户覆盖时沿当前应用的完整默认绑定运行。
    /// 参数说明: 无。
    /// 返回：不禁用任何默认命令的空映射。
    public init() {
        overrides = []
    }

    /// 业务作用：全部用户覆盖作为一份配置校验，不让同一组合由菜单位置决定执行命令。
    /// 参数说明:
    /// - overrides: 每个稳定命令至多一项完整覆盖，空绑定明确禁用默认组合。
    /// 返回：最多两千项且没有跨命令重复组合的配置；未知命令仅保留身份，不能因此取得执行资格。
    public init(_ overrides: [CommandKeyBinding]) throws {
        guard overrides.count <= Self.maximumCommands else {
            throw NateError.message("快捷键映射超过两千项命令。")
        }
        var commands: Set<String> = []
        var shortcuts: Set<KeyboardShortcut> = []
        for binding in overrides {
            guard commands.insert(binding.command).inserted else {
                throw NateError.message("快捷键映射重复定义同一命令。")
            }
            for shortcut in binding.shortcuts {
                guard shortcuts.insert(shortcut).inserted else {
                    throw NateError.message("同一快捷键不能同时覆盖多个命令。")
                }
            }
        }
        self.overrides = overrides
    }

    /// 业务作用：修改单个命令仍完整复验整份配置，恢复默认和清空绑定具有不同语义。
    /// 参数说明:
    /// - command: 当前明确选择的命令身份。
    /// - shortcuts: 完整新组合，空数组取消全部绑定，空值移除覆盖以恢复当前默认。
    /// 返回：完整有效的新配置；冲突或超量时保留原映射。
    public func updating(_ command: String, shortcuts: [KeyboardShortcut]?) throws -> KeyboardMap {
        var next = overrides
        let index = next.firstIndex {
            $0.command == command
        }
        if let shortcuts {
            let binding = try CommandKeyBinding(command: command, shortcuts: shortcuts)
            if let index {
                next[index] = binding
            }
            else {
                next.append(binding)
            }
        }
        else if let index {
            next.remove(at: index)
        }
        return try KeyboardMap(next)
    }
}
