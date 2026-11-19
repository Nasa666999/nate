import Foundation
import NateCore

public struct RunCommandDraft: Sendable {
    public let id: UUID?
    public let name: String
    public let executable: String
    public let argumentsJSON: String
    public let directory: String
    public let shortcut: KeyboardShortcut?

    /// 业务作用：用户输入作为一份完整草稿交给应用准备，读取字段不会保存配置或启动进程。
    /// 参数说明:
    /// - id: 原配置身份，新建输入为空。
    /// - name: 当前完整名称原文。
    /// - executable: 当前完整程序模板。
    /// - argumentsJSON: 未截断的参数数组草稿，解析由后台完成。
    /// - directory: 完整目录模板，空字符串表示使用默认目录。
    /// - shortcut: 当前明确捕获的可选组合。
    /// 返回：没有执行回调或文件访问权的不可变输入快照。
    public init(
        id: UUID?,
        name: String,
        executable: String,
        argumentsJSON: String,
        directory: String,
        shortcut: KeyboardShortcut?
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.argumentsJSON = argumentsJSON
        self.directory = directory
        self.shortcut = shortcut
    }
}
