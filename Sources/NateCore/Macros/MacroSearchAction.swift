import Foundation

public enum MacroSearchCommand: String, Codable, CaseIterable, Sendable {
    case next, previous, replaceOne, replaceAll
}

public struct MacroSearchAction: Codable, Equatable, Sendable {
    public let command: MacroSearchCommand
    public let options: SearchOptions
    public let stayAfterReplace: Bool

    /// 业务作用：搜索宏固定完整原文、全部选项和替换后停留策略，不读取播放时的查找窗口设置。
    /// 参数说明:
    /// - command: 当前文档内明确支持的查找或替换动作。
    /// - options: 录制时完整条件及计算预算。
    /// - stayAfterReplace: 单次替换后停留在结果范围，而非自动导航下一处。
    /// 返回：通过容量和动作门禁的不可变配置；无效输入不产生部分动作。
    public init(command: MacroSearchCommand, options: SearchOptions, stayAfterReplace: Bool) throws {
        self.command = command
        self.options = options
        self.stayAfterReplace = stayAfterReplace
        try validateSupport()
    }

    /// 业务作用：直接构造和归档解码均校验搜索资源预算，宏不能借选项取得无限匹配或替换容量。
    /// 参数说明: 无。
    /// 返回：合法当前文档动作继续；空查询、超量、非法预算或反向正则明确拒绝。
    public func validateSupport() throws {
        try options.validateInput()
        guard options.replacement.utf8.count <= 64 * 1024 * 1024,
            (1...100_000).contains(options.maxMatches), (1...5_000_000).contains(options.stepLimit)
        else {
            throw NateError.message("宏搜索的替换文字、匹配数量或计算预算超出允许范围。")
        }
        guard options.mode != .regex || command != .previous && !options.backwards else {
            throw NateError.message("正则默认禁用反向搜索；请使用正向匹配导航。")
        }
    }
}
