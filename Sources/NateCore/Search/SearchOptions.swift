import Foundation

public enum SearchMode: String, Sendable, Codable, CaseIterable {
    case literal = "普通"
    case extended = "扩展"
    case regex = "正则表达式"
}

public struct SearchOptions: Sendable, Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case query
        case replacement
        case mode
        case caseSensitive
        case wholeWord
        case wordBoundaries
        case dotMatchesNewline
        case wrap
        case backwards
        case selectionOnly
        case recursive
        case includeHidden
        case ignoreOpenBuffers
        case maxMatches
        case stepLimit
    }

    public var query = ""
    public var replacement = ""
    public var mode: SearchMode = .literal
    public var caseSensitive = false
    public var wholeWord = false
    public var wordBoundaries = WordBoundarySettings()
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
            && lhs.wordBoundaries == rhs.wordBoundaries
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

    /// 业务作用：旧查找归档缺少附加词规则时沿用默认，已有完整搜索字段仍须逐项有效。
    /// 参数说明:
    /// - decoder: 完整查找或宏中固定的查找条件。
    /// 返回：全部条件及词边界合法时恢复，未知或损坏词规则不进入搜索任务。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decode(String.self, forKey: .query)
        replacement = try values.decode(String.self, forKey: .replacement)
        mode = try values.decode(SearchMode.self, forKey: .mode)
        caseSensitive = try values.decode(Bool.self, forKey: .caseSensitive)
        wholeWord = try values.decode(Bool.self, forKey: .wholeWord)
        wordBoundaries =
            try values.decodeIfPresent(WordBoundarySettings.self, forKey: .wordBoundaries)
            ?? WordBoundarySettings()
        dotMatchesNewline = try values.decode(Bool.self, forKey: .dotMatchesNewline)
        wrap = try values.decode(Bool.self, forKey: .wrap)
        backwards = try values.decode(Bool.self, forKey: .backwards)
        selectionOnly = try values.decode(Bool.self, forKey: .selectionOnly)
        recursive = try values.decode(Bool.self, forKey: .recursive)
        includeHidden = try values.decode(Bool.self, forKey: .includeHidden)
        ignoreOpenBuffers = try values.decode(Bool.self, forKey: .ignoreOpenBuffers)
        maxMatches = try values.decode(Int.self, forKey: .maxMatches)
        stepLimit = try values.decode(Int.self, forKey: .stepLimit)
    }

    /// 业务作用：搜索和宏固定当时的完整词边界规则，默认规则省略新增字段以保留既有归档形态。
    /// 参数说明:
    /// - encoder: 本次明确保存的完整查找条件。
    /// 返回：完整字段写入归档，之后的全局词规则变化不改写已保存的请求。
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(query, forKey: .query)
        try values.encode(replacement, forKey: .replacement)
        try values.encode(mode, forKey: .mode)
        try values.encode(caseSensitive, forKey: .caseSensitive)
        try values.encode(wholeWord, forKey: .wholeWord)
        if wordBoundaries != WordBoundarySettings() {
            try values.encode(wordBoundaries, forKey: .wordBoundaries)
        }
        try values.encode(dotMatchesNewline, forKey: .dotMatchesNewline)
        try values.encode(wrap, forKey: .wrap)
        try values.encode(backwards, forKey: .backwards)
        try values.encode(selectionOnly, forKey: .selectionOnly)
        try values.encode(recursive, forKey: .recursive)
        try values.encode(includeHidden, forKey: .includeHidden)
        try values.encode(ignoreOpenBuffers, forKey: .ignoreOpenBuffers)
        try values.encode(maxMatches, forKey: .maxMatches)
        try values.encode(stepLimit, forKey: .stepLimit)
    }
}
