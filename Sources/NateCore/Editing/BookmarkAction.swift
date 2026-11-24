public enum BookmarkAction: String, Sendable {
    case toggle = "bookmark"
    case next = "nextBookmark"
    case previous = "previousBookmark"
    case clear = "clearBookmarks"
    case invert = "invertBookmarks"
    case copy = "copyBookmarks"
    case cut = "cutBookmarks"
    case replace = "replaceBookmarks"
    case delete = "deleteBookmarks"
    case deleteOthers = "deleteUnbookmarked"

    /// 业务作用：将正文写入动作与只读元数据动作分开校验权限。
    /// 参数说明: 无。
    /// 返回：剪切、替换和两类删除需要正文写入权。
    public var changesText: Bool {
        [.cut, .replace, .delete, .deleteOthers].contains(self)
    }

    /// 业务作用：明确哪些动作在用户主动执行时发布系统剪贴板。
    /// 参数说明: 无。
    /// 返回：复制和剪切使用剪贴板输出。
    public var changesClipboard: Bool {
        self == .copy || self == .cut
    }

    /// 业务作用：录制及播放共用明确许可的书签语义，剪贴板和正文批量命令另有实际输入合同。
    /// 参数说明: 无。
    /// 返回：受支持动作的中文名称；其它动作没有书签宏语义。
    public var macroTitle: String? {
        switch self {
        case .toggle:
            return "切换书签"
        case .next:
            return "下一个书签"
        case .previous:
            return "上一个书签"
        case .clear:
            return "清除全部书签"
        case .invert:
            return "反转书签"
        case .copy, .cut, .replace, .delete, .deleteOthers:
            return nil
        }
    }
}
