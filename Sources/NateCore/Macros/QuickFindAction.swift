public enum QuickFindAction: String, Sendable {
    case selectNext = "selectFindNext"
    case selectPrevious = "selectFindPrevious"
    case volatileNext = "volatileFindNext"
    case volatilePrevious = "volatileFindPrevious"

    /// 业务作用：明确区分临时查询与更新当前查找条件的用户意图。
    /// 参数说明: 无。
    /// 返回：临时查找为真，执行时保留完整查找窗口与历史。
    public var isVolatile: Bool {
        self == .volatileNext || self == .volatilePrevious
    }

    /// 业务作用：快捷动作方向独立于查找窗口当前方向选项。
    /// 参数说明: 无。
    /// 返回：上一个匹配动作为反向，其余为正向。
    public var backwards: Bool {
        self == .selectPrevious || self == .volatilePrevious
    }

    /// 业务作用：让宏列表和详情显示保存的快捷查询方式及方向。
    /// 参数说明: 无。
    /// 返回：与实际菜单语义一致的用户动作名称。
    public var title: String {
        switch self {
        case .selectNext: "选中并查找下一处"
        case .selectPrevious: "选中并查找上一处"
        case .volatileNext: "临时查找下一处"
        case .volatilePrevious: "临时查找上一处"
        }
    }
}
