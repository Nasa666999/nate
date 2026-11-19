import Foundation

public struct NamedRunCommand: Sendable, Equatable, Identifiable {
    public static let maximumArguments = 1024
    public static let maximumFieldBytes = 1_048_576
    public static let maximumTemplateBytes = 4 * 1_048_576
    public let id: UUID
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let directory: String?
    public let shortcut: KeyboardShortcut?
    public let retainedBytes: Int

    /// 业务作用：命名运行配置只保存结构化程序、参数与工作目录模板，保存和载入不取得进程执行权。
    /// 参数说明:
    /// - id: 稳定配置身份，重命名和修改字段时保持不变。
    /// - name: 一至一百二十八个标量的用户名称，不含控制符或首尾空白。
    /// - executable: 程序绝对路径模板，执行前必须完整展开并检查实际路径。
    /// - arguments: 有序参数模板，每个数组元素始终是一项数据参数。
    /// - directory: 工作目录模板，空值沿当前文件目录或进程默认目录。
    /// - shortcut: 由运行配置管理的可选完整组合。
    /// 返回：全部字段和估计容量合法的不可变配置；未知变量留待明确预览时解释，不执行模板。
    public init(
        id: UUID = UUID(),
        name: String,
        executable: String,
        arguments: [String],
        directory: String? = nil,
        shortcut: KeyboardShortcut? = nil
    ) throws {
        guard !name.isEmpty, name.utf8.count <= 512, name.unicodeScalars.count <= 128,
            name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
            !name.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                    || $0.properties.generalCategory == .paragraphSeparator
            }), !executable.isEmpty, directory?.isEmpty != true,
            arguments.count <= Self.maximumArguments
        else {
            throw NateError.message("运行配置名称、程序或参数数量无效。")
        }
        var total = 0
        for field in [executable] + arguments
            + (directory.map {
                [$0]
            } ?? [])
        {
            guard field.utf8.count <= Self.maximumFieldBytes, !field.utf8.contains(0),
                field.utf8.count <= Self.maximumTemplateBytes - total
            else {
                throw NateError.message("运行配置字段不得含 NUL，单字段最多 1 MiB，完整模板最多 4 MiB。")
            }
            total += field.utf8.count
        }
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.shortcut = shortcut
        retainedBytes = total + name.utf8.count + arguments.count * 32 + 256
    }

    /// 业务作用：配置比较保留原始 Unicode 模板身份，规范等价文字不能掩盖用户实际改动。
    /// 参数说明:
    /// - lhs: 第一份完整定义。
    /// - rhs: 第二份完整定义。
    /// 返回：稳定身份、字段原字节、参数顺序与逻辑绑定全部相同时为真。
    public static func == (lhs: NamedRunCommand, rhs: NamedRunCommand) -> Bool {
        guard lhs.id == rhs.id, lhs.name.utf8.elementsEqual(rhs.name.utf8),
            lhs.executable.utf8.elementsEqual(rhs.executable.utf8), lhs.shortcut == rhs.shortcut,
            lhs.arguments.count == rhs.arguments.count,
            zip(lhs.arguments, rhs.arguments).allSatisfy({
                $0.utf8.elementsEqual($1.utf8)
            })
        else {
            return false
        }
        switch (lhs.directory, rhs.directory) {
        case (nil, nil): return true
        case (.some(let first), .some(let second)): return first.utf8.elementsEqual(second.utf8)
        default: return false
        }
    }
}

public struct RunCommandLibrary: Sendable, Equatable {
    public static let maximumCommands = 256
    public static let maximumRetainedBytes = 16 * 1_048_576
    public let commands: [NamedRunCommand]

    /// 业务作用：没有已保存运行配置时不安装外部命令或默认执行项。
    /// 参数说明: 无。
    /// 返回：完整空命令库。
    public init() {
        commands = []
    }

    /// 业务作用：完整命令库同时校验稳定身份、名称、快捷键和累计占用，不能发布部分成功的配置。
    /// 参数说明:
    /// - commands: 用户明确保留的有序完整定义。
    /// 返回：最多二百五十六项且估计保留容量不超过 16 MiB 的命令库。
    public init(_ commands: [NamedRunCommand]) throws {
        guard commands.count <= Self.maximumCommands else {
            throw NateError.message("命名运行配置超过二百五十六项。")
        }
        var identities: Set<UUID> = []
        var names: Set<String> = []
        var shortcuts: Set<KeyboardShortcut> = []
        var retained = 0
        for command in commands {
            guard identities.insert(command.id).inserted, names.insert(command.name).inserted else {
                throw NateError.message("运行配置包含重复身份或名称。")
            }
            if let shortcut = command.shortcut, !shortcuts.insert(shortcut).inserted {
                throw NateError.message("运行配置包含重复快捷键。")
            }
            guard command.retainedBytes <= Self.maximumRetainedBytes - retained else {
                throw NateError.message("运行配置估计保留容量超过 16 MiB。")
            }
            retained += command.retainedBytes
        }
        self.commands = commands
    }
}
