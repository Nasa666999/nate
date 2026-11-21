import Foundation

public enum EditorAppearance: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public struct EditorDisplaySettings: Codable, Sendable, Equatable {
    public let format: Int
    public let fontName: String?
    public let fontSize: Double
    public let appearance: EditorAppearance
    public let wrapLines: Bool
    public let showSymbols: Bool

    /// 业务作用：没有用户配置时采用系统等宽字体及系统外观，不在启动时改变正文。
    /// 参数说明: 无。
    /// 返回：十三点字号、系统主题且关闭自动换行与空白符号的完整默认设置。
    public init() {
        format = 1
        fontName = nil
        fontSize = 13
        appearance = .system
        wrapLines = false
        showSymbols = false
    }

    /// 业务作用：完整验证字体、字号和外观配置，非法值不被静默夹取为另一项用户选择。
    /// 参数说明:
    /// - fontName: 明确字体的 PostScript 名称，为空时使用系统等宽字体。
    /// - fontSize: 七至七十二点的有限字号，可含小数。
    /// - appearance: 跟随系统、浅色或深色的明确选择。
    /// - wrapLines: 是否按视口自动换行。
    /// - showSymbols: 是否显示空白及控制符号。
    /// 返回：整份配置合法时建立，不合规时拒绝发布。
    public init(
        fontName: String?,
        fontSize: Double,
        appearance: EditorAppearance,
        wrapLines: Bool,
        showSymbols: Bool
    ) throws {
        guard fontSize.isFinite, (7...72).contains(fontSize) else {
            throw NateError.message("正文字号必须为 7 到 72 点的有限数值。")
        }
        if let fontName {
            guard !fontName.isEmpty, fontName.utf8.count <= 256,
                fontName.unicodeScalars.contains(where: {
                    !$0.properties.isWhitespace
                }),
                fontName.unicodeScalars.allSatisfy({
                    ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                })
            else {
                throw NateError.message("字体名称必须为至多 256 UTF-8 字节的有效名称，不能包含控制符。")
            }
        }
        format = 1
        self.fontName = fontName
        self.fontSize = fontSize
        self.appearance = appearance
        self.wrapLines = wrapLines
        self.showSymbols = showSymbols
    }

    /// 业务作用：读取显示配置时复验协议与完整字段，损坏或未知格式不能进入原生排版。
    /// 参数说明:
    /// - decoder: 完整显示配置归档。
    /// 返回：已知格式且全部值合法时恢复，否则拒绝整份配置。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .format) == 1 else {
            throw NateError.message("显示配置格式无法识别。")
        }
        try self.init(
            fontName: values.decodeIfPresent(String.self, forKey: .fontName),
            fontSize: values.decode(Double.self, forKey: .fontSize),
            appearance: values.decode(EditorAppearance.self, forKey: .appearance),
            wrapLines: values.decode(Bool.self, forKey: .wrapLines),
            showSymbols: values.decode(Bool.self, forKey: .showSymbols)
        )
    }
}
