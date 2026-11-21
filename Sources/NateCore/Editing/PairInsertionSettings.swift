import Foundation

public struct PairInsertionSettings: Sendable, Equatable, Codable {
    public let enabled: Bool
    public let pairs: [AutomaticPair]
    public let skipExisting: Bool
    public let closeMarkupTags: Bool

    /// 业务作用：未配置时保留字面输入习惯，明确启用后才使用预装括号和引号定义。
    /// 参数说明: 无。
    /// 返回：默认关闭、允许越过已有闭合符，并预装圆方花括号及三种常用引号。
    public init() {
        enabled = false
        skipExisting = true
        closeMarkupTags = false
        pairs = AutomaticPair.standardPairs
    }

    /// 业务作用：完整发布全部配对定义，同一开端不能因顺序不同而产生不同闭合内容。
    /// 参数说明:
    /// - enabled: 是否对普通直接输入启用配对。
    /// - pairs: 最多六十四项、开端原字节唯一的完整定义，空列表允许暂停所有配对。
    /// - skipExisting: 是否越过当前同字节闭合符。
    /// - closeMarkupTags: 是否独立启用 HTML/XML 开始标签结束时的闭合输入。
    /// 返回：完整且无歧义的配置；重复开端或过量列表时拒绝整份。
    public init(enabled: Bool, pairs: [AutomaticPair], skipExisting: Bool, closeMarkupTags: Bool = false)
        throws
    {
        guard pairs.count <= 64,
            Set(
                pairs.map {
                    Data($0.opening.utf8)
                }
            ).count == pairs.count
        else {
            throw NateError.message("自动配对最多 64 项，开端原字节不得重复。")
        }
        self.enabled = enabled
        self.pairs = pairs
        self.skipExisting = skipExisting
        self.closeMarkupTags = closeMarkupTags
    }

    /// 业务作用：选择真实直接输入对应的定义，原字节宏及其它插入入口不调用此策略。
    /// 参数说明:
    /// - input: 当前完整系统直接输入文字。
    /// 返回：明确启用且输入恰为任一端时提供独立动作，其它输入按原字面通道提交。
    public func command(for input: String) throws -> PairInputCommand? {
        guard enabled,
            let pair = pairs.first(where: {
                input.utf8.elementsEqual($0.opening.utf8) || input.utf8.elementsEqual($0.closing.utf8)
            })
        else {
            return nil
        }
        return try PairInputCommand(
            pair: pair,
            input: input,
            skipExisting: skipExisting
        )
    }

    /// 业务作用：偏好恢复复验整份容量和开端唯一性，损坏列表不能部分生效。
    /// 参数说明:
    /// - decoder: 完整自动配对配置。
    /// 返回：全部字段与定义合法时恢复，任何异常时拒绝整份。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            enabled: values.decode(Bool.self, forKey: .enabled),
            pairs: values.decode([AutomaticPair].self, forKey: .pairs),
            skipExisting: values.decode(Bool.self, forKey: .skipExisting),
            closeMarkupTags: values.decodeIfPresent(Bool.self, forKey: .closeMarkupTags) ?? false
        )
    }
}
