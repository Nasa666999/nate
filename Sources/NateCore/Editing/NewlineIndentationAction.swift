import Foundation

public enum NewlineIndentationAction: Sendable, Equatable {
    case inherit
    case increase
    case decrease
    case expandPair
    /// 开端跨行时，内层和闭合行都采用真实开端的原始空白。
    case expandAlignedPair(prefix: String)
    /// 对齐保留明确来源的纯空白前缀，增减层级采用当前 Tab 配置，并服从整批读取与输出容量。
    case align(prefix: String, levels: Int)
}

enum NewlineIndentationText {
    /// 业务作用：新行按当前 Tab 配置增减缩进，明确对齐仍保留来源行的混合空白和整批输入边界。
    /// 参数说明:
    /// - prefix: 当前插入点之前已经确认的原行前导空白。
    /// - ending: 当前文档真实插入换行。
    /// - action: 固定语言证据产生的结构动作或明确对齐前缀。
    /// - settings: 当前语言的 Tab 宽度与新空白方式。
    /// - extra: 虚拟或部分 Tab 边缘需要继承的明确空格。
    /// - maximumBytes: 本目标仍有资格使用的完整输出容量。
    /// - budget: 全部光标共同拥有的继续资格。
    /// 返回：完整输入及其中的光标字节位置，空白、容量、列数或执行资格不足时抛错。
    static func prepare(
        prefix: String,
        ending: String,
        action: NewlineIndentationAction,
        settings: TabSettings,
        extra: Int,
        maximumBytes: Int,
        budget: SelectionPreparationBudget
    ) throws -> (text: String, caret: Int) {
        let adjusted: String
        var pairedPrefix: String?
        switch action {
        case .inherit:
            adjusted = prefix
        case .increase, .expandPair:
            adjusted = try NewlineIndentationPrefix.shift(
                prefix,
                levels: 1,
                settings: settings,
                budget: budget
            )
            if action == .expandPair {
                pairedPrefix = prefix
            }
        case .expandAlignedPair(let origin):
            adjusted = try NewlineIndentationPrefix.shift(
                origin,
                levels: 1,
                settings: settings,
                budget: budget
            )
            pairedPrefix = origin
        case .decrease:
            adjusted = try NewlineIndentationPrefix.shift(
                prefix,
                levels: -1,
                settings: settings,
                budget: budget
            )
        case .align(let origin, let levels):
            adjusted = try NewlineIndentationPrefix.shift(
                origin,
                levels: levels,
                settings: settings,
                budget: budget
            )
        }
        let first = ending.utf8.count + adjusted.utf8.count + extra
        let trailing = pairedPrefix.map { ending.utf8.count + $0.utf8.count } ?? 0
        // 真实前缀、边缘空白及第二个换行完整计入容量，不能发布只包含部分光标或半个成对结构的输入。
        guard extra >= 0, first <= maximumBytes, trailing <= maximumBytes - first else {
            throw NateError.message("完整结构换行超过正文或输出容量。")
        }
        var text = ending + adjusted + String(repeating: " ", count: extra)
        if let pairedPrefix {
            text += ending + pairedPrefix
        }
        try budget.check()
        return (text, first)
    }
}
