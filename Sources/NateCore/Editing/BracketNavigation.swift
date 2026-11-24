public enum BracketNavigation: String, Sendable {
    case jump = "matchingBracket"
    case selectPair = "selectBracketPair"
    case selectInside = "selectInsideBracket"

    /// 业务作用：把括号菜单和宏中的稳定标识显示为实际导航语义。
    /// 参数说明: 无。
    /// 返回：与执行范围对应的中文动作名称。
    public var title: String {
        switch self {
        case .jump:
            return "跳到匹配括号"
        case .selectPair:
            return "选择匹配括号及内容"
        case .selectInside:
            return "选择括号内的内容"
        }
    }
}
