import Foundation
import NateSearch

public struct SearchResultCondition: Sendable {
    public let options: SearchOptions

    /// 业务作用：固定已执行批次的匹配选项，替换原文不属于只读结果的来源证据。
    /// 参数说明:
    /// - options: 实际执行时已归一化的查找条件。
    /// 返回：去除重复表达式与替换文本的值快照，表达式由批次独立保存。
    public init(_ options: SearchOptions = SearchOptions()) {
        var value = options
        value.query = ""
        value.replacement = ""
        self.options = value
    }

    /// 业务作用：让历史结果直接说明原请求的匹配模式和范围，后续控件变化不改写旧批次。
    /// 参数说明: 无。
    /// 返回：包含全部布尔选项与执行预算的单行说明。
    public var summary: String {
        let flags: [(String, Bool)] = [
            ("区分大小写", options.caseSensitive), ("全词", options.wholeWord),
            ("点匹配换行", options.dotMatchesNewline), ("反向", options.backwards),
            ("循环", options.wrap), ("仅选区", options.selectionOnly),
            ("递归", options.recursive), ("隐藏文件", options.includeHidden),
            ("已打开文件使用磁盘内容", options.ignoreOpenBuffers),
        ]
        return
            ([options.mode.rawValue]
            + flags.map {
                "\($0.0)：\($0.1 ? "是" : "否")"
            }
            + ["匹配上限：\(options.maxMatches)", "执行步数：\(options.stepLimit)"]).joined(separator: " · ")
    }
}

public struct SearchResultPreferences: Codable, Sendable, Equatable {
    public var clearPrevious = false
    public var oneRowPerLine = false

    enum CodingKeys: String, CodingKey {
        case clearPrevious, oneRowPerLine
    }

    /// 业务作用：结果默认保留多批历史，清除策略独立于正文搜索条件。
    /// 参数说明: 无。
    /// 返回：新查询追加历史的默认偏好。
    public init() {}

    /// 业务作用：既有结果设置缺少显示合并偏好时保留逐匹配展示，错误类型不静默更改用户设置。
    /// 参数说明:
    /// - decoder: 搜索归档中的结果偏好字段。
    /// 返回：可选字段采用既有默认值，存在但类型不符时整体解码失败。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clearPrevious = try values.decodeIfPresent(Bool.self, forKey: .clearPrevious) ?? false
        oneRowPerLine = try values.decodeIfPresent(Bool.self, forKey: .oneRowPerLine) ?? false
    }
}

public enum SearchResultRemoval: Sendable {
    case batch(UUID)
    case file(batch: UUID, file: UUID)
    case hits(batch: UUID, file: UUID, hits: [UUID])
    case note(batch: UUID, index: Int)
}
