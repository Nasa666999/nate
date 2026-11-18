import Foundation

public struct SelectedTextHighlightOptions: Codable, Sendable, Equatable {
    public var enabled = true
    public var caseSensitive = false
    public var wholeWord = true
    public var useFindOptions = false
    public var anotherView = false

    /// 业务作用：选中文本高亮具有独立偏好，不修改查找条件或持久颜色组。
    /// 参数说明: 无。
    /// 返回：默认启用、忽略大小写、仅完整词，只处理当前视图且不复用查找选项。
    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case caseSensitive
        case wholeWord
        case useFindOptions
        case anotherView
    }

    /// 业务作用：恢复少量独立智能高亮选项，旧配置缺失字段保持业务默认值。
    /// 参数说明:
    /// - decoder: 用户保存的选项数据。
    /// 返回：完整有效配置；类型损坏时整体解码失败，不产生部分设置。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        caseSensitive = try values.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        wholeWord = try values.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
        useFindOptions = try values.decodeIfPresent(Bool.self, forKey: .useFindOptions) ?? false
        anotherView = try values.decodeIfPresent(Bool.self, forKey: .anotherView) ?? false
    }
}
