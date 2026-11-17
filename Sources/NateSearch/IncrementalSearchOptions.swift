import Foundation

public struct IncrementalSearchOptions: Sendable, Codable, Equatable {
    public var caseSensitive = false
    public var wholeWord = false
    public var wrap = true

    /// 业务作用：保存增量查找自己的常用选项，不改变完整查找窗口的模式和表达式。
    /// 参数说明: 无。
    /// 返回：普通字面匹配、忽略大小写并允许循环的默认选项。
    public init() {}

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
