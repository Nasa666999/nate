import NateCore

extension FindReplaceWindow {
    /// 业务作用：全局词规则变化后使旧搜索及文件替换请求失效，并保留当前完整输入。
    /// 参数说明:
    /// - settings: 当前明确发布的完整词字符规则。
    /// 返回：新请求采用新规则，旧配置身份不再拥有发布或写盘权限。
    public func setWordBoundaries(_ settings: WordBoundarySettings) {
        guard wordBoundaries != settings else {
            return
        }
        wordBoundaries = settings
        optionsChanged()
    }
}
