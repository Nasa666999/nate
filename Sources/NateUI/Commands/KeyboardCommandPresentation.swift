import Foundation
import NateCore

public struct KeyboardCommandPresentation: Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let defaults: [KeyboardShortcut]
    public let active: [KeyboardShortcut]
    public let requested: [KeyboardShortcut]?
    public let notes: [String]
    public let available: Bool
    public let managedElsewhere: Bool

    /// 业务作用：管理面板分别展示完整期望、实际启用和默认绑定，冲突项不能以可执行外观掩盖失效状态。
    /// 参数说明:
    /// - id: 实际命令目录使用的稳定身份。
    /// - title: 当前完整命令名称。
    /// - category: 当前菜单层级或命令类别。
    /// - defaults: 当前应用提供的完整默认组合。
    /// - active: 本次解析实际启用的组合。
    /// - requested: 用户完整覆盖，空数组表示禁用，空值表示沿默认。
    /// - notes: 冲突或不可应用原因的完整说明。
    /// - available: 当前应用确实提供该身份。
    /// - managedElsewhere: 绑定由对应命令库管理，不能在两个配置中同时覆盖。
    /// 返回：不含任何执行回调或命令访问资格的只读呈现值。
    public init(
        id: String,
        title: String,
        category: String,
        defaults: [KeyboardShortcut],
        active: [KeyboardShortcut],
        requested: [KeyboardShortcut]?,
        notes: [String],
        available: Bool,
        managedElsewhere: Bool
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.defaults = defaults
        self.active = active
        self.requested = requested
        self.notes = notes
        self.available = available
        self.managedElsewhere = managedElsewhere
    }
}
