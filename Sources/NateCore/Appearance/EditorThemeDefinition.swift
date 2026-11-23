import Foundation

public enum EditorThemeColorRole: String, Codable, Sendable, CaseIterable {
    case background
    case foreground
    case caret
    case selectionBackground
    case selectionForeground
    case currentLineBackground
    case lineNumber
    case gutterBackground
    case whitespace
    case indentGuide
    case longLineGuide
    case bracketMatchBackground
    case bracketMismatchBackground
    case foldMarker
    case bookmark
    case modificationSaved
    case modificationUnsaved
    case linkForeground
}

public struct EditorThemeDefinition: Codable, Sendable, Equatable {
    public let format: Int
    public let name: String
    public let colors: [String: String]
    public let kindStyles: [String: EditorThemeStyle]
    public let languageStyles: [String: [String: EditorThemeStyle]]

    /// 业务作用：主题作为独立完整配置固定整体颜色、通用类别和逐语言词法覆盖，保持正文权限分离。
    /// 参数说明:
    /// - name: 至多 256 UTF-8 字节且包含可见内容的主题名称。
    /// - colors: 采用已知整体角色名的明确 RGB，缺省角色继承所属视图。
    /// - kindStyles: 通用正文、关键字、字面、注释等类别覆盖。
    /// - languageStyles: 稳定语言 ID 下的完整词法身份覆盖，尚未安装的语言原样保留。
    /// 返回：字段、数量和原字节预算全部合法时建立主题，否则整体拒绝。
    public init(
        name: String,
        colors: [String: String] = [:],
        kindStyles: [String: EditorThemeStyle] = [:],
        languageStyles: [String: [String: EditorThemeStyle]] = [:]
    ) throws {
        try Self.validateName(name, maximumBytes: 256)
        let kinds: Set<String> = [
            "text", "keyword", "string", "comment", "number", "heading", "tag", "punctuation",
        ]
        guard colors.count <= EditorThemeColorRole.allCases.count,
            kindStyles.count <= kinds.count,
            kindStyles.keys.allSatisfy({
                kinds.contains($0)
            }),
            languageStyles.count <= 512
        else {
            throw NateError.message("主题包含未知整体角色、语法类别或超过 512 种语言。")
        }
        var normalized: [String: String] = [:]
        var remaining = 4 * 1024 * 1024, count = kindStyles.count
        for (role, color) in colors {
            guard EditorThemeColorRole(rawValue: role) != nil else {
                throw NateError.message("主题包含无法识别的整体颜色角色。")
            }
            normalized[role] = try EditorThemeStyle.canonicalColor(color)
        }
        for (kind, style) in kindStyles {
            try Self.consume(kind, style: style, remaining: &remaining)
        }
        for (language, styles) in languageStyles {
            try Self.validateName(language, maximumBytes: 256)
            guard styles.count <= 512, styles.count <= 8192 - count,
                language.utf8.count <= remaining
            else {
                throw NateError.message("主题超过每语言 512 项、合计 8192 项或 4 MiB 原字段预算。")
            }
            count += styles.count
            remaining -= language.utf8.count
            for (identity, style) in styles {
                try Self.validateName(identity, maximumBytes: 256)
                try Self.consume(identity, style: style, remaining: &remaining)
            }
        }
        format = 1
        self.name = name
        self.colors = normalized
        self.kindStyles = kindStyles
        self.languageStyles = languageStyles
    }

    /// 业务作用：主题名称与资源身份保持原拼写，同时排除控制内容和无可见内容的名称。
    /// 参数说明:
    /// - value: 当前名称或完整资源身份。
    /// - maximumBytes: 当前字段的 UTF-8 上限。
    /// 返回：名称有界且包含可见内容时通过，否则拒绝整个主题。
    static func validateName(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            value.unicodeScalars.contains(where: {
                !$0.properties.isWhitespace
            }),
            value.unicodeScalars.allSatisfy({
                ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            })
        else {
            throw NateError.message("主题名称或样式身份为空、超长或包含控制内容。")
        }
    }

    /// 业务作用：编码前先限制主题的有效原字段，外部配置不能通过许多合法小项放大内存请求。
    /// 参数说明:
    /// - identity: 当前类别或完整词法身份。
    /// - style: 已完成单项校验的有限样式。
    /// - remaining: 所有样式共同持有的原字段余量。
    /// 返回：当前字段完整计入预算；容量不足时拒绝整个主题。
    private static func consume(
        _ identity: String,
        style: EditorThemeStyle,
        remaining: inout Int
    ) throws {
        for value in [identity, style.foreground ?? "", style.background ?? "", style.fontName ?? ""] {
            guard value.utf8.count <= remaining else {
                throw NateError.message("主题有效原字段超过 4 MiB。")
            }
            remaining -= value.utf8.count
        }
    }

    /// 业务作用：主题归档只恢复已知完整格式，未知字段或代次不会被部分采用。
    /// 参数说明:
    /// - decoder: 已通过原文件容量与唯一键门禁的主题解码器。
    /// 返回：全部样式与字段合法时恢复主题，否则保留调用方此前的配置。
    public init(from decoder: Decoder) throws {
        try EditorThemeCodingKey.validate(
            decoder,
            allowed: ["format", "name", "colors", "kindStyles", "languageStyles"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .format) == 1 else {
            throw NateError.message("主题归档格式无法识别，未采用部分内容。")
        }
        try self.init(
            name: values.decode(String.self, forKey: .name),
            colors: values.decodeIfPresent([String: String].self, forKey: .colors) ?? [:],
            kindStyles: values.decodeIfPresent([String: EditorThemeStyle].self, forKey: .kindStyles) ?? [:],
            languageStyles: values.decodeIfPresent(
                [String: [String: EditorThemeStyle]].self,
                forKey: .languageStyles
            ) ?? [:]
        )
    }
}
