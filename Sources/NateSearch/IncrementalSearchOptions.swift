import Foundation

public struct IncrementalSearchOptions: Sendable, Codable, Equatable {
    public var caseSensitive = false
    public var wholeWord = false
    public var wrap = true
    public var highlightAll = false

    /// 业务作用：保存增量查找自己的常用选项，不改变完整查找窗口的模式和表达式。
    /// 参数说明: 无。
    /// 返回：普通字面匹配、忽略大小写、允许循环且默认关闭全部高亮。
    public init() {}

    enum CodingKeys: String, CodingKey {
        case caseSensitive
        case wholeWord
        case wrap
        case highlightAll
    }

    /// 业务作用：旧增量选项缺少新增开关时恢复原默认值，不使既有用户配置解码失败。
    /// 参数说明:
    /// - decoder: 用户保存的独立增量选项。
    /// 返回：已提供字段使用原值，缺失循环默认开启，缺失全部高亮默认关闭。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        caseSensitive = try values.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        wholeWord = try values.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        wrap = try values.decodeIfPresent(Bool.self, forKey: .wrap) ?? true
        highlightAll = try values.decodeIfPresent(Bool.self, forKey: .highlightAll) ?? false
    }

    /// 业务作用：将增量栏的完整已确认输入交给统一搜索引擎，方向由导航动作决定。
    /// 参数说明:
    /// - query: 未转义且已确认的完整原文。
    /// 返回：全文普通搜索选项，保留大小写、全词和循环设置。
    public func searchOptions(query: String) -> SearchOptions {
        var options = SearchOptions()
        options.query = query
        options.caseSensitive = caseSensitive
        options.wholeWord = wholeWord
        options.wrap = wrap
        return options
    }
}
