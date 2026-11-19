import Foundation

public enum SearchMode: String, Sendable, Codable, CaseIterable {
    case literal = "普通"
    case extended = "扩展"
    case regex = "正则表达式"
}

public struct SearchOptions: Sendable, Codable, Equatable {
    public var query = ""
    public var replacement = ""
    public var mode: SearchMode = .literal
    public var caseSensitive = false
    public var wholeWord = false
    public var dotMatchesNewline = false
    public var wrap = true
    public var backwards = false
    public var selectionOnly = false
    public var recursive = true
    public var includeHidden = false
    public var ignoreOpenBuffers = false
    public var maxMatches = 100_000
    public var stepLimit = 5_000_000

    /// 业务作用：建立可独立保存和复用的查找条件。
    /// 参数说明: 无。
    /// 返回：普通搜索默认选项。
    public init() {}

    /// 业务作用：按实际搜索输入的字符编码区分请求，规范等价的 Unicode 文本不能沿用另一表达式的发布权。
    /// 参数说明:
    /// - lhs: 已捕获的完整查找条件。
    /// - rhs: 需要复验或比较的当前条件。
    /// 返回：全部选项一致且查找、替换原文的 UTF-8 完全相同时为真。
    public static func == (lhs: SearchOptions, rhs: SearchOptions) -> Bool {
        lhs.mode == rhs.mode
            && lhs.caseSensitive == rhs.caseSensitive
            && lhs.wholeWord == rhs.wholeWord
            && lhs.dotMatchesNewline == rhs.dotMatchesNewline
            && lhs.wrap == rhs.wrap
            && lhs.backwards == rhs.backwards
            && lhs.selectionOnly == rhs.selectionOnly
            && lhs.recursive == rhs.recursive
            && lhs.includeHidden == rhs.includeHidden
            && lhs.ignoreOpenBuffers == rhs.ignoreOpenBuffers
            && lhs.maxMatches == rhs.maxMatches
            && lhs.stepLimit == rhs.stepLimit
            && lhs.query.utf8.elementsEqual(rhs.query.utf8)
            && lhs.replacement.utf8.elementsEqual(rhs.replacement.utf8)
    }

    /// 业务作用：在读取正文之前校验完整查找输入，普通、扩展和正则使用相同 UTF-8 容量合同。
    /// 参数说明: 无。
    /// 返回：非空且不超过 1 MiB 时允许继续，超限明确失败而不截断表达式。
    public func validateInput() throws {
        guard !query.isEmpty else {
            throw NateError.message("请输入查找内容。")
        }
        guard query.utf8.count <= 1_048_576 else {
            throw NateError.message("查找内容超过 1 MiB UTF-8 输入上限，请缩小完整表达式。")
        }
    }
}
