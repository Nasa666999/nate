import Foundation

public struct PreparedExternalCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL?

    /// 业务作用：程序、参数和工作目录先完整展开为固定数据，确认界面与实际进程使用同一份命令。
    /// 参数说明:
    /// - executableTemplate: 程序绝对路径的原始模板，不自动查找 shell 或 PATH。
    /// - argumentTemplates: 有序原始参数数组，每项保持独立。
    /// - directoryTemplate: 可选绝对工作目录模板。
    /// - values: 当前固定文档快照提供的完整变量。
    /// - defaultDirectory: 未提供目录模板时固定使用的本地目录，空值继承进程当前目录。
    /// 返回：可完整预览的固定命令；未知、缺失、NUL、非绝对路径或累计超量拒绝，不启动进程。
    public init(
        executableTemplate: String,
        argumentTemplates: [String],
        directoryTemplate: String?,
        values: [String: String],
        defaultDirectory: URL?
    ) throws {
        guard argumentTemplates.count <= 4096 else {
            throw ExternalProcessFailure(reason: "外部命令参数超过四千零九十六项。")
        }
        let executable = try CommandTemplate.expand(executableTemplate, values: values)
        guard executable.hasPrefix("/"), !executable.utf8.contains(0) else {
            throw ExternalProcessFailure(reason: "展开后的程序必须是无 NUL 的本地绝对路径。")
        }
        var total = executable.utf8.count
        var arguments: [String] = []
        for template in argumentTemplates {
            let value = try CommandTemplate.expand(template, values: values)
            // 每项先检查整批剩余容量，重复引用完整选区不能分配无界的参数数组后才失败。
            guard !value.utf8.contains(0), value.utf8.count <= 1_048_576 - total else {
                throw ExternalProcessFailure(reason: "展开后的完整程序和参数不得含 NUL 或超过 1 MiB。")
            }
            total += value.utf8.count
            arguments.append(value)
        }
        let directory: URL?
        if let directoryTemplate {
            let path = try CommandTemplate.expand(directoryTemplate, values: values)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw ExternalProcessFailure(reason: "展开后的工作目录必须是无 NUL 的本地绝对路径。")
            }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }
        else {
            directory = defaultDirectory
        }
        if let directory {
            // 默认目录同样不能借 URL 主机、凭据或协议把当前命令改向非本地位置。
            guard directory.isFileURL,
                directory.host == nil || directory.host == "" || directory.host == "localhost",
                directory.user == nil, directory.password == nil, directory.port == nil,
                !directory.path.utf8.contains(0), directory.path.utf8.count <= 1_048_576
            else {
                throw ExternalProcessFailure(reason: "默认工作目录不是可用的本地文件路径。")
            }
        }
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
    }
}
