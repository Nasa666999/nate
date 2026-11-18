import AppKit
import NateCore
import NateSearch

public struct SelectedTextHighlightSettings: Equatable, Sendable {
    public let options: SelectedTextHighlightOptions
    public let generation: UUID
    public let findGeneration: UUID?
    public let findCaseSensitive: Bool
    public let findWholeWord: Bool

    /// 业务作用：每个临时匹配固定独立设置身份，复用查找选项时同时固定查找配置身份。
    /// 参数说明:
    /// - options: 智能高亮自己的完整偏好。
    /// - generation: 偏好每次明确变化后的新身份。
    /// - findGeneration: 复用查找条件时的配置身份，独立模式为空。
    /// - findCaseSensitive: 查找窗口当前大小写选项。
    /// - findWholeWord: 查找窗口当前整词选项。
    /// 返回：无正文与视图引用的不可变设置，偏好往返变化不能复用旧身份。
    public init(
        options: SelectedTextHighlightOptions,
        generation: UUID,
        findGeneration: UUID?,
        findCaseSensitive: Bool,
        findWholeWord: Bool
    ) {
        self.options = options
        self.generation = generation
        self.findGeneration = findGeneration
        self.findCaseSensitive = findCaseSensitive
        self.findWholeWord = findWholeWord
    }
}

@MainActor
public struct SelectedTextHighlightContext {
    public let source: EditorView
    public let settings: SelectedTextHighlightSettings

    /// 业务作用：目标视图从窗口取得真实活动选择来源，不使用共享正文中另一克隆的光标。
    /// 参数说明:
    /// - source: 窗口当前真正持有选择的活动编辑视图。
    /// - settings: 当前完整设置与配置身份。
    /// 返回：仅用于主执行域来源复验的上下文，不直接交给后台计算。
    public init(source: EditorView, settings: SelectedTextHighlightSettings) {
        self.source = source
        self.settings = settings
    }
}

struct SelectedTextHighlightKey: Equatable {
    let target: ObjectIdentifier
    let targetRevision: UInt64
    let source: ObjectIdentifier
    let sourceView: ObjectIdentifier
    let sourceRevision: UInt64
    let selectionGeneration: UUID
    let selections: [TextSelection]
    let scopes: [ByteRange]
    let settings: SelectedTextHighlightSettings
}

@MainActor
final class SelectedTextHighlightRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?
    var key: SelectedTextHighlightKey?
    var failure: String?

    /// 业务作用：每个视图分别持有视口任务和失败状态，克隆不共享临时匹配结果。
    /// 参数说明: 无。
    /// 返回：未绑定任何正文或来源的运行期状态。
    init() {}
}
