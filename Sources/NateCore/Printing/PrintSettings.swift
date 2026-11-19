import Foundation

public enum PrintColorMode: String, Sendable, CaseIterable, Codable {
    case document
    case inverted
    case blackOnWhite
    case noBackground
}

public struct PrintSettings: Sendable, Equatable, Codable {
    public let color: PrintColorMode
    public let fontScale: Double
    public let lineNumbers: Bool
    public let formFeedPageBreaks: Bool
    public let marginTop: Double
    public let marginBottom: Double
    public let marginLeft: Double
    public let marginRight: Double
    public let header: PrintDecoration
    public let footer: PrintDecoration

    /// 业务作用：固定独立打印呈现，不让屏幕缩放、折叠或边距变更改写正文与保存点。
    /// 参数说明:
    /// - color: 当前文档颜色、反色、黑白或去背景方案。
    /// - fontScale: 正文打印字号比例，范围为 0.25–4。
    /// - lineNumbers: 是否在独立边栏绘制原逻辑行号。
    /// - formFeedPageBreaks: 是否把 FF 解释为实际分页意图。
    /// - marginTop: 上页边距，毫米。
    /// - marginBottom: 下页边距，毫米。
    /// - marginLeft: 左页边距，毫米。
    /// - marginRight: 右页边距，毫米。
    /// - header: 已验证的三栏页眉，省略时为空。
    /// - footer: 已验证的三栏页脚，省略时为空。
    /// 返回：全部有限且各边距为 0–100 毫米的配置；具体纸张可用面积由实际分页再次验证。
    public init(
        color: PrintColorMode = .blackOnWhite,
        fontScale: Double = 1,
        lineNumbers: Bool = false,
        formFeedPageBreaks: Bool = false,
        marginTop: Double = 15,
        marginBottom: Double = 15,
        marginLeft: Double = 15,
        marginRight: Double = 15,
        header: PrintDecoration? = nil,
        footer: PrintDecoration? = nil
    ) throws {
        guard fontScale.isFinite, (0.25...4).contains(fontScale),
            [marginTop, marginBottom, marginLeft, marginRight].allSatisfy({
                $0.isFinite && (0...100).contains($0)
            })
        else {
            throw NateError.message("打印缩放必须为 25%–400%，各页边距必须为 0–100 毫米。")
        }
        self.color = color
        self.fontScale = fontScale
        self.lineNumbers = lineNumbers
        self.formFeedPageBreaks = formFeedPageBreaks
        self.marginTop = marginTop
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.header = try header ?? PrintDecoration()
        self.footer = try footer ?? PrintDecoration()
    }

    /// 业务作用：归档恢复重新执行边距、缩放和页眉页脚验证，损坏字段不能流入系统打印状态。
    /// 参数说明:
    /// - decoder: 原打印配置归档。
    /// 返回：完整合法配置；缺失、非法枚举或越界值整体失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            color: container.decode(PrintColorMode.self, forKey: .color),
            fontScale: container.decode(Double.self, forKey: .fontScale),
            lineNumbers: container.decode(Bool.self, forKey: .lineNumbers),
            formFeedPageBreaks: container.decode(Bool.self, forKey: .formFeedPageBreaks),
            marginTop: container.decode(Double.self, forKey: .marginTop),
            marginBottom: container.decode(Double.self, forKey: .marginBottom),
            marginLeft: container.decode(Double.self, forKey: .marginLeft),
            marginRight: container.decode(Double.self, forKey: .marginRight),
            header: container.decode(PrintDecoration.self, forKey: .header),
            footer: container.decode(PrintDecoration.self, forKey: .footer)
        )
    }
}
