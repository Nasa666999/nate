import Foundation

public enum AutomaticIndentation: String, Sendable, Codable, CaseIterable {
    case disabled
    case inherit
    case language
}

public struct IndentationSettings: Sendable, Equatable, Codable {
    public let automatic: AutomaticIndentation
    public let backspaceUnindents: Bool

    /// 业务作用：自动换行缩进与前导空白退格分别配置，既有正文不因偏好改变而被转换。
    /// 参数说明:
    /// - automatic: 关闭、继承原行，或依据适用语言结构调整新行缩进。
    /// - backspaceUnindents: 普通空光标在前导空白中是否退至上一个 Tab 停靠位。
    /// 返回：完整输入规则；省略参数时继承原行缩进并逐字退格。
    public init(automatic: AutomaticIndentation = .inherit, backspaceUnindents: Bool = false) {
        self.automatic = automatic
        self.backspaceUnindents = backspaceUnindents
    }
}
