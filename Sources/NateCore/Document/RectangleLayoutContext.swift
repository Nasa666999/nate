import Foundation

public struct RectangleLayoutContext: Sendable, Codable, Equatable {
    public let fontName: String
    public let pointSize: Double
    public let fontTraits: UInt32
    public let layoutWidth: Double
    public let rightToLeft: Bool
    public let styleIdentity: String

    /// 业务作用：视觉矩形绑定产生边缘的字体、排版宽度和样式证据，相同像素不能在另一布局下取得删除权限。
    /// 参数说明:
    /// - fontName: 原生字体的稳定名称。
    /// - pointSize: 实际字体点数。
    /// - fontTraits: 原生字体的实际特征位。
    /// - layoutWidth: 产生原生字形的实际容器宽度，不换行时为编辑器固定宽度。
    /// - rightToLeft: 段落基础方向。
    /// - styleIdentity: 影响字体样式的实际资源 SHA-256。
    /// 返回：可持久化且有界的原生布局证据；非法字体、宽度或摘要拒绝。
    public init(
        fontName: String,
        pointSize: Double,
        fontTraits: UInt32,
        layoutWidth: Double,
        rightToLeft: Bool,
        styleIdentity: String
    ) throws {
        guard !fontName.isEmpty, fontName.utf8.count <= 1024, !fontName.utf8.contains(0),
            pointSize.isFinite, pointSize > 0, pointSize <= 4096,
            layoutWidth.isFinite, (1...1_000_000_000).contains(layoutWidth),
            styleIdentity.utf8.count == 64,
            styleIdentity.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw NateError.message("矩形布局的字体、容器或样式证据无效。")
        }
        self.fontName = fontName
        self.pointSize = pointSize
        self.fontTraits = fontTraits
        self.layoutWidth = layoutWidth
        self.rightToLeft = rightToLeft
        self.styleIdentity = styleIdentity
    }

    /// 业务作用：恢复和外部完整选择沿同一字体与宽度门禁解码，不把非法数值夹成当前默认布局。
    /// 参数说明:
    /// - decoder: 所属归档已经限制原始字节数的解码器。
    /// 返回：完整合法布局证据，未知字段语义由所属归档格式控制。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fontName: values.decode(String.self, forKey: .fontName),
            pointSize: values.decode(Double.self, forKey: .pointSize),
            fontTraits: values.decode(UInt32.self, forKey: .fontTraits),
            layoutWidth: values.decode(Double.self, forKey: .layoutWidth),
            rightToLeft: values.decode(Bool.self, forKey: .rightToLeft),
            styleIdentity: values.decode(String.self, forKey: .styleIdentity)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, pointSize, fontTraits, layoutWidth, rightToLeft, styleIdentity
    }
}
