import Foundation

public enum TextLinkDisplayMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case underlinedForeground
    case underlinedBackground
    case foregroundOnHover
    case backgroundOnHover
}

public struct TextLinkSettings: Codable, Sendable, Equatable {
    public static let basePrefixes = ["ftp://", "http://", "https://", "mailto:", "file://"]
    public static let defaultAdditionalPrefixes =
        "svn:// cvs:// git:// imap:// irc:// irc6:// ircs:// ldap:// ldaps:// news: telnet:// "
        + "gopher:// ssh:// sftp:// smb:// skype: snmp:// spotify: steam:// sms: slack:// chrome:// bitcoin:"

    public let format: Int
    public let mode: TextLinkDisplayMode
    public let additionalPrefixes: String

    /// 业务作用：正文链接默认显示下划线并在悬停时使用链接前景色，读取偏好不打开任何目标。
    /// 参数说明: 无。
    /// 返回：五项基本协议及明确附加协议的默认配置，实际打开仍须用户主动操作。
    public init() {
        format = 1
        mode = .underlinedForeground
        additionalPrefixes = Self.defaultAdditionalPrefixes
    }

    /// 业务作用：附加协议作为完整受限字面前缀校验，非法或重复定义不能部分进入点击识别。
    /// 参数说明:
    /// - mode: 关闭、下划线或仅悬停，以及前景或背景提示方式。
    /// - additionalPrefixes: 至多 2048 个 ASCII 字节和三十二项协议，空白分隔且保留原草稿。
    /// 返回：全部协议及容量合法时建立配置，否则拒绝整份配置。
    public init(mode: TextLinkDisplayMode, additionalPrefixes: String) throws {
        guard additionalPrefixes.utf8.count <= 2048,
            additionalPrefixes.utf8.allSatisfy({
                [9, 10, 13, 32].contains($0) || (33...126).contains($0)
            })
        else {
            throw NateError.message("链接附加协议须为至多 2048 个 ASCII 字节，使用空格或换行分隔。")
        }
        let values = additionalPrefixes.split(whereSeparator: \.isWhitespace)
        guard values.count <= 32 else {
            throw NateError.message("链接附加协议最多三十二项，未采用部分配置。")
        }
        var seen = Set(Self.basePrefixes)
        for value in values {
            let bytes = Array(value.utf8)
            guard bytes.count <= 64, let colon = bytes.firstIndex(of: 58), colon > 0,
                Self.isLetter(bytes[0]),
                bytes[..<colon].allSatisfy({
                    Self.isLetter($0) || (48...57).contains($0) || [43, 45, 46].contains($0)
                }),
                Array(bytes[colon...]) == [58] || Array(bytes[colon...]) == [58, 47, 47]
            else {
                throw NateError.message("链接协议须以 ASCII 字母开头，使用协议名加 : 或 ://，每项最多 64 字节。")
            }
            guard seen.insert(value.lowercased()).inserted else {
                throw NateError.message("链接附加协议与已有项重复，大小写不区分。")
            }
        }
        format = 1
        self.mode = mode
        self.additionalPrefixes = additionalPrefixes
    }

    /// 业务作用：完整已验证的协议列表按原定义提供，基本协议不会因附加草稿为空而消失。
    /// 参数说明: 无。
    /// 返回：五项基本协议及原顺序附加协议，不进行网络访问或系统协议查询。
    public var prefixes: [String] {
        Self.basePrefixes + additionalPrefixes.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 业务作用：恢复链接偏好时仍验证格式、完整字段和全部协议，未知归档不能授权点击打开。
    /// 参数说明:
    /// - decoder: 完整链接偏好归档。
    /// 返回：已知格式及全部值有效时恢复，否则拒绝整份配置。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .format) == 1 else {
            throw NateError.message("链接显示配置格式无法识别。")
        }
        try self.init(
            mode: values.decode(TextLinkDisplayMode.self, forKey: .mode),
            additionalPrefixes: values.decode(String.self, forKey: .additionalPrefixes)
        )
    }

    /// 业务作用：URI 协议首字符只使用 ASCII 字母，不把 Unicode 外观相似字符解释为协议权限。
    /// 参数说明:
    /// - byte: 协议定义中的一个 ASCII 字节。
    /// 返回：字节为 ASCII 大写或小写字母时为真。
    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}
