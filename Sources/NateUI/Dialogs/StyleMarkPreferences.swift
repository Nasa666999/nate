public struct StyleMarkPreferences: Codable, Sendable, Equatable {
    public var caseSensitive = false
    public var wholeWord = true

    /// 业务作用：五组样式共享独立的字面匹配偏好，不借用查找窗口的模式、方向或表达式。
    /// 参数说明: 无。
    /// 返回：忽略大小写且仅匹配完整词的默认样式选项。
    public init() {}
}

extension FindReplaceWindow {
    /// 业务作用：主菜单样式偏好进入搜索设置归档，普通查找条件的执行身份保持独立。
    /// 参数说明:
    /// - preferences: 用户明确选择的样式字面匹配选项。
    /// 返回：配置快照更新并通知持久化入口，不启动查找或改变颜色。
    public func setStylePreferences(_ preferences: StyleMarkPreferences) {
        stylePreferences = preferences
        stateChanged()
    }
}
