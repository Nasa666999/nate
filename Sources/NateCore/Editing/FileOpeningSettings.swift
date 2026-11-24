import Foundation

public enum FileDirectoryMode: String, Sendable, Codable, CaseIterable {
    case lastUsed
    case currentDocument
    case custom
}

public enum FileOpenWindowMode: String, Sendable, Codable, CaseIterable {
    case reuseWindow
    case newWindow
}

public struct FileOpeningSettings: Sendable, Codable, Equatable {
    public let defaultLanguage: String
    public let lineEnding: LineEnding
    public let recentFileLimit: Int
    public let directoryMode: FileDirectoryMode
    public let customDirectory: String
    public let finderWindowMode: FileOpenWindowMode

    private enum CodingKeys: String, CodingKey {
        case defaultLanguage
        case lineEnding
        case recentFileLimit
        case directoryMode
        case customDirectory
        case finderWindowMode
    }

    /// 业务作用：新建文档采用纯文本与 LF，文件对话框沿用上次目录，Finder 复用窗口，保留三十条最近文件。
    /// 参数说明: 无。
    /// 返回：不需要访问文件系统或改写现有文档的默认偏好。
    public init() {
        defaultLanguage = "normal"
        lineEnding = .lf
        recentFileLimit = 30
        directoryMode = .lastUsed
        customDirectory = ""
        finderWindowMode = .reuseWindow
    }

    /// 业务作用：完整验证文件入口与新建文档偏好，目录只是用户草稿，不在读取配置时访问磁盘。
    /// 参数说明:
    /// - defaultLanguage: 内置语言或 UDL 的稳定身份，当前资源缺席时仍保留原身份。
    /// - lineEnding: 只用于以后新建文档的输入换行。
    /// - recentFileLimit: 显示及记录最近文件的上限，零表示停用。
    /// - directoryMode: 文件对话框的起始目录来源。
    /// - customDirectory: 自定义绝对路径，未启用时可以为空并保留草稿。
    /// - finderWindowMode: Finder 打开每组路径时复用窗口或建立独立窗口。
    /// 返回：所有字段完整合法时建立偏好；无效身份、容量或目录格式整体拒绝。
    public init(
        defaultLanguage: String,
        lineEnding: LineEnding,
        recentFileLimit: Int,
        directoryMode: FileDirectoryMode,
        customDirectory: String,
        finderWindowMode: FileOpenWindowMode = .reuseWindow
    ) throws {
        guard !defaultLanguage.isEmpty, defaultLanguage.utf8.count <= 8192,
            !defaultLanguage.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || [0x2028, 0x2029].contains($0.value)
            }),
            (0...200).contains(recentFileLimit)
        else {
            throw NateError.message("默认语言身份须为 8 KiB 以内的完整名称，最近文件数量须为 0–200。")
        }
        guard customDirectory.utf8.count <= 8192, !customDirectory.utf8.contains(0),
            customDirectory.isEmpty || customDirectory.utf8.first == 47,
            directoryMode != .custom || !customDirectory.isEmpty
        else {
            throw NateError.message("自定义目录须为不含 NUL、最多 8 KiB 的绝对路径。")
        }
        self.defaultLanguage = defaultLanguage
        self.lineEnding = lineEnding
        self.recentFileLimit = recentFileLimit
        self.directoryMode = directoryMode
        self.customDirectory = customDirectory
        self.finderWindowMode = finderWindowMode
    }

    /// 业务作用：归档恢复执行与原生表单相同的完整约束，损坏内容不能授予文件入口偏好。
    /// 参数说明:
    /// - decoder: 完整文件偏好归档。
    /// 返回：全部必填字段有效时恢复，旧记录缺少窗口策略时复用窗口，显式非法值整体失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            defaultLanguage: values.decode(String.self, forKey: .defaultLanguage),
            lineEnding: values.decode(LineEnding.self, forKey: .lineEnding),
            recentFileLimit: values.decode(Int.self, forKey: .recentFileLimit),
            directoryMode: values.decode(FileDirectoryMode.self, forKey: .directoryMode),
            customDirectory: values.decode(String.self, forKey: .customDirectory),
            finderWindowMode: values.contains(.finderWindowMode)
                ? values.decode(FileOpenWindowMode.self, forKey: .finderWindowMode) : .reuseWindow
        )
    }

    /// 业务作用：原始路径和语言编码决定偏好来源，规范等价的不同字符序列不能共用旧表单权限。
    /// 参数说明:
    /// - lhs: 已固定的完整偏好。
    /// - rhs: 需要复验的当前偏好。
    /// 返回：所有枚举、数量及两个字符串的原始 UTF-8 编码完全一致时为真。
    public static func == (lhs: FileOpeningSettings, rhs: FileOpeningSettings) -> Bool {
        lhs.lineEnding == rhs.lineEnding && lhs.recentFileLimit == rhs.recentFileLimit
            && lhs.directoryMode == rhs.directoryMode
            && lhs.finderWindowMode == rhs.finderWindowMode
            && lhs.defaultLanguage.utf8.elementsEqual(rhs.defaultLanguage.utf8)
            && lhs.customDirectory.utf8.elementsEqual(rhs.customDirectory.utf8)
    }
}
