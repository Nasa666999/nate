import Foundation
import NateCore

public struct SearchPresentationPreferences: Codable, Sendable {
    public var fillFromSelection = true
    public var fillFromWord = true
    public var fillMultiline = true
    public var fillLimit = 1024
    public var selectionThreshold = 1024

    /// 业务作用：把自动填入与选区内自动勾选分开保存，默认阈值均按标量字符计量。
    /// 参数说明: 无。
    /// 返回：允许短选区、光标词和多行填入，连续选区达到 1024 个字符时自动勾选。
    public init() {}

    /// 业务作用：限制自动填入与判断预算，避免偏好配置要求展开无界选区。
    /// 参数说明: 无。
    /// 返回：填入阈值为 1 至 262144、自动勾选为 0 至 262144 时通过，零只表示手动控制勾选。
    public func validate() throws {
        guard (1...262_144).contains(fillLimit), (0...262_144).contains(selectionThreshold) else {
            throw NateError.message("填入字符上限须为 1–262144；选区自动勾选阈值须为 0–262144，0 表示手动控制。")
        }
    }
}

public struct SearchPresentationContext: Sendable {
    public let query: String?
    public let selectionEligible: Bool
    public let selectionOnly: Bool?
}

public enum SearchPresentation {
    /// 业务作用：在原快照上独立决定填入文本与连续选区范围，巨大选区只判断阈值，不复制全文。
    /// 参数说明:
    /// - text: 当前焦点文档的不可变正文。
    /// - selections: 当前视图的完整选区，多选和虚拟列不作为连续搜索范围。
    /// - preferences: 用户的填入与自动勾选设置。
    /// - wordBoundaries: 本次光标取词固定的完整字符规则。
    /// 返回：可选的完整填入原文、选区是否可用及自动勾选意图；手动控制时勾选意图为空。
    public static func context(
        text: PieceTree,
        selections: [TextSelection],
        preferences: SearchPresentationPreferences,
        wordBoundaries: WordBoundarySettings = WordBoundarySettings()
    ) throws -> SearchPresentationContext {
        try preferences.validate()
        let single = selections.count == 1 && selections[0].virtualColumn == 0 ? selections[0] : nil
        let selected = single?.range
        let eligible = selected?.isEmpty == false
        var checked: Bool? = preferences.selectionThreshold == 0 ? nil : false
        var candidate: ByteRange?
        if let selected, !selected.isEmpty {
            let count = try text.boundedScalarCount(
                in: selected,
                limit: max(preferences.fillLimit + 1, preferences.selectionThreshold)
            )
            if preferences.selectionThreshold > 0 {
                checked = count >= preferences.selectionThreshold
            }
            if preferences.fillFromSelection, count <= preferences.fillLimit {
                candidate = selected
            }
        }
        else if preferences.fillFromSelection, preferences.fillFromWord, let single {
            candidate = text.wordRange(
                at: single.head,
                maximumScalars: preferences.fillLimit,
                wordBoundaries: wordBoundaries
            )
        }
        let query = candidate.map {
            text.text(in: $0)
        }
        let allowed =
            preferences.fillMultiline
            || query?.utf8.contains(where: {
                $0 == 10 || $0 == 13
            }) != true
        return SearchPresentationContext(
            query: allowed ? query : nil,
            selectionEligible: eligible,
            selectionOnly: checked
        )
    }
}
