import Foundation

public struct PrintDecoration: Sendable, Equatable, Codable {
    public let left: String
    public let middle: String
    public let right: String
    public let fontName: String
    public let fontSize: Double
    public let bold: Bool
    public let italic: Bool

    /// 业务作用：固定单行页眉或页脚的三个独立区域与字体，非法配置不能进入实际分页。
    /// 参数说明:
    /// - left: 左侧文字与受支持变量模板。
    /// - middle: 中间文字与变量模板。
    /// - right: 右侧文字与变量模板。
    /// - fontName: 明确字体名称；空字符串沿用正文打印字体。
    /// - fontSize: 六至七十二点的实际页眉或页脚字号。
    /// - bold: 是否请求粗体。
    /// - italic: 是否请求斜体。
    /// 返回：各区最多四 KiB 且变量完整合法的固定配置；非法值整体失败。
    public init(
        left: String = "",
        middle: String = "",
        right: String = "",
        fontName: String = "",
        fontSize: Double = 9,
        bold: Bool = false,
        italic: Bool = false
    ) throws {
        guard fontName.utf8.count <= 256,
            fontName.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            fontSize.isFinite, (6...72).contains(fontSize)
        else {
            throw NateError.message("打印页眉页脚字体必须为有效名称和 6–72 点字号。")
        }
        for value in [left, middle, right] {
            guard value.utf8.count <= 4096,
                value.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                })
            else {
                throw NateError.message("打印页眉页脚各区最多 4 KiB，且不能包含控制字符或换行。")
            }
            _ = try PrintTemplate(value)
        }
        self.left = left
        self.middle = middle
        self.right = right
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
    }

    /// 业务作用：配置归档通过与原生输入相同的完整验证，不让解码绕过字体和模板边界。
    /// 参数说明:
    /// - decoder: 原打印配置归档。
    /// 返回：完整合法配置；缺失、未知类型或越界字段失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            left: container.decode(String.self, forKey: .left),
            middle: container.decode(String.self, forKey: .middle),
            right: container.decode(String.self, forKey: .right),
            fontName: container.decode(String.self, forKey: .fontName),
            fontSize: container.decode(Double.self, forKey: .fontSize),
            bold: container.decode(Bool.self, forKey: .bold),
            italic: container.decode(Bool.self, forKey: .italic)
        )
    }

    /// 业务作用：页眉页脚原文按实际 UTF-8 区分，规范等价文字也不能掩盖真实配置变化。
    /// 参数说明:
    /// - lhs: 原配置。
    /// - rhs: 待比较配置。
    /// 返回：全部原文字节、字体和呈现选项相同时为真。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.left.utf8.elementsEqual(rhs.left.utf8)
            && lhs.middle.utf8.elementsEqual(rhs.middle.utf8)
            && lhs.right.utf8.elementsEqual(rhs.right.utf8)
            && lhs.fontName.utf8.elementsEqual(rhs.fontName.utf8)
            && lhs.fontSize == rhs.fontSize && lhs.bold == rhs.bold && lhs.italic == rhs.italic
    }
}
