import Foundation

public struct EditorThemeStyle: Codable, Sendable, Equatable {
    public private(set) var foreground: String?
    public private(set) var background: String?
    public private(set) var fontName: String?
    public private(set) var fontSize: Int?
    public private(set) var fontStyle: Int?

    /// 业务作用：主题没有明确覆盖时保留全部下层样式，不制造默认颜色或字体请求。
    /// 参数说明: 无。
    /// 返回：所有字段都处于继承状态的合法样式。
    public init() {}

    /// 业务作用：高优先级样式只替换自己明确声明的字段，零字体装饰仍是有效覆盖。
    /// 参数说明:
    /// - fallback: 已校验的下层主题或类别样式。
    /// 返回：保持单项校验不变量的完整组合值，不修改任一原样式。
    public func merging(over fallback: EditorThemeStyle) -> EditorThemeStyle {
        var value = fallback
        if let foreground {
            value.foreground = foreground
        }
        if let background {
            value.background = background
        }
        if let fontName {
            value.fontName = fontName
        }
        if let fontSize {
            value.fontSize = fontSize
        }
        if let fontStyle {
            value.fontStyle = fontStyle
        }
        return value
    }

    /// 业务作用：主题样式只接纳有界颜色和字体字段，缺省值明确继承下层呈现。
    /// 参数说明:
    /// - foreground: 带井号的六位 RGB 前景，为空时继承。
    /// - background: 带井号的六位 RGB 背景，为空时继承。
    /// - fontName: 明确字体名称，为空时继承；当前系统缺少该字体时保留原名。
    /// - fontSize: 一至五百一十二点的明确字号，为空时继承。
    /// - fontStyle: 粗体、斜体及下划线的三位完整组合，零表示明确无装饰，为空时继承。
    /// 返回：完整字段合法时建立样式，非法值整体拒绝。
    public init(
        foreground: String? = nil,
        background: String? = nil,
        fontName: String? = nil,
        fontSize: Int? = nil,
        fontStyle: Int? = nil
    ) throws {
        self.foreground = try foreground.map(Self.canonicalColor)
        self.background = try background.map(Self.canonicalColor)
        if let fontName {
            guard !fontName.isEmpty, fontName.utf8.count <= 256,
                fontName.unicodeScalars.contains(where: {
                    !$0.properties.isWhitespace
                }),
                fontName.unicodeScalars.allSatisfy({
                    ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                })
            else {
                throw NateError.message("主题字体名称必须为至多 256 UTF-8 字节的有效名称，不能包含控制符。")
            }
        }
        guard
            fontSize.map({
                (1...512).contains($0)
            }) ?? true,
            fontStyle.map({
                (0...7).contains($0)
            }) ?? true
        else {
            throw NateError.message("主题字号须为 1 至 512 点，字体装饰须为零至七的完整组合。")
        }
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontStyle = fontStyle
    }

    /// 业务作用：主题中的明确 RGB 采用唯一拼写，等价十六进制大小写不产生不同呈现身份。
    /// 参数说明:
    /// - value: 用户提供的完整颜色字段。
    /// 返回：合法六位 RGB 的井号及大写形式；其它格式拒绝。
    public static func canonicalColor(_ value: String) throws -> String {
        guard value.utf8.count == 7 else {
            throw NateError.message("主题颜色必须采用 #RRGGBB 的完整六位 RGB。")
        }
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes.first == 35,
            bytes.dropFirst().allSatisfy({
                $0 >= 48 && $0 <= 57 || $0 >= 65 && $0 <= 70 || $0 >= 97 && $0 <= 102
            })
        else {
            throw NateError.message("主题颜色必须采用 #RRGGBB 的完整六位 RGB。")
        }
        return value.uppercased()
    }

    /// 业务作用：从完整归档恢复样式时再次执行字段校验，非法字体或颜色不进入原生排版。
    /// 参数说明:
    /// - decoder: 所属主题的受限解码器。
    /// 返回：所有已知字段合法时恢复，未知字段或非法值整体拒绝。
    public init(from decoder: Decoder) throws {
        try EditorThemeCodingKey.validate(
            decoder,
            allowed: ["foreground", "background", "fontName", "fontSize", "fontStyle"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            foreground: values.decodeIfPresent(String.self, forKey: .foreground),
            background: values.decodeIfPresent(String.self, forKey: .background),
            fontName: values.decodeIfPresent(String.self, forKey: .fontName),
            fontSize: values.decodeIfPresent(Int.self, forKey: .fontSize),
            fontStyle: values.decodeIfPresent(Int.self, forKey: .fontStyle)
        )
    }
}
