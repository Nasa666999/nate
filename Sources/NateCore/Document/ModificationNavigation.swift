public enum ModificationNavigation: String, Sendable {
    case previous = "previousModification"
    case next = "nextModification"

    /// 业务作用：让菜单与宏使用相同的实际修改导航名称。
    /// 参数说明: 无。
    /// 返回：对应方向的用户可读动作名。
    public var title: String {
        switch self {
        case .previous: "上一处修改"
        case .next: "下一处修改"
        }
    }
}
