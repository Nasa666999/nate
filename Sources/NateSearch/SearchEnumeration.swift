import Foundation

public enum SearchEnumeration: String, Sendable {
    case batch
    case navigation
    case nonEmpty = "nonempty"
}

public struct SearchMatchContext: Sendable {
    public let prefix: NSRange
    public let suffix: NSRange

    /// 业务作用：固定单次继续搜索实际可见的替换上下文，后续替换不重新解释范围边界。
    /// 参数说明:
    /// - prefix: 本轮搜索起点至完整命中起点的 UTF-16 范围。
    /// - suffix: 完整命中终点至本轮可见上下文终点的 UTF-16 范围。
    /// 返回：绑定原快照坐标的前后文本证据，不持有或修改正文。
    public init(prefix: NSRange, suffix: NSRange) {
        self.prefix = prefix
        self.suffix = suffix
    }
}

enum RegexProgress {
    /// 业务作用：被拒绝的空匹配越过当前标量的剩余部分或完整 CRLF，避免在代理项及行尾序列内部重复定位。
    /// 参数说明:
    /// - input: 完整正文的有界 UTF-16 读取器。
    /// - position: 当前空匹配的原始 UTF-16 位置。
    /// 返回：严格前进的位置；原终点之后的值表示本轮已结束。
    static func next(_ input: SearchInput, after position: Int) -> Int {
        if position + 1 < input.count {
            let first = input[position]
            let second = input[position + 1]
            if first == 13 && second == 10
                || (0xd800...0xdbff).contains(first) && (0xdc00...0xdfff).contains(second)
            {
                return position + 2
            }
        }
        return position + 1
    }
}
