public struct SearchMarkPreferences: Codable, Sendable, Equatable {
    public var clearPrevious = false
    public var bookmarkLines = false

    /// 业务作用：查找颜色与书签默认分别管理，执行标记时可明确选择是否保留旧颜色及添加书签。
    /// 参数说明: 无。
    /// 返回：保留既有查找标记、不自动添加书签的默认偏好。
    public init() {}
}
