import Foundation
import NateCore
import NateSearch

public struct SearchUserPreferences: Codable, Sendable {
    private let format: Int
    public let options: SearchOptions
    public let stayAfterReplace: Bool
    public let confirmsOpenReplacement: Bool
    public let presentation: SearchPresentationPreferences
    public let inputFont: SearchInputFont
    public let results: SearchResultPreferences
    public let marking: SearchMarkPreferences
    public let styling: StyleMarkPreferences

    /// 业务作用：从当前搜索状态提取可迁移偏好，查询、替换原文、路径和历史不进入配置包。
    /// 参数说明:
    /// - state: 当前完整搜索窗口状态。
    /// 返回：仅含行为、显示、字体和结果偏好的独立快照；取词规则仍由独立词边界配置管理。
    public init(state: SearchWindowState) {
        format = 1
        var flags = state.options
        flags.query = ""
        flags.replacement = ""
        flags.wordBoundaries = WordBoundarySettings()
        flags.maxMatches = SearchOptions().maxMatches
        flags.stepLimit = SearchOptions().stepLimit
        options = flags
        stayAfterReplace = state.stayAfterReplace
        confirmsOpenReplacement = state.confirmsOpenReplacement
        presentation = state.presentation
        inputFont = state.inputFont
        results = state.results
        marking = state.marking
        styling = state.styling
    }

    /// 业务作用：可迁移搜索归档只接受已知的完整字段结构，未知字段不能携带历史或私人输入后随导出传播。
    /// 参数说明:
    /// - data: 至多 64 KiB 的完整独立搜索偏好 JSON。
    /// 返回：格式、参数和全部嵌套键均可完整解释的偏好；未知、重复或缺失字段整份拒绝。
    public static func decode(_ data: Data) throws -> SearchUserPreferences {
        guard data.count <= 65_536 else {
            throw NateError.message("搜索用户偏好超过 64 KiB。")
        }
        try UserConfigurationJSON.validate(data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        else {
            throw NateError.invalidText
        }
        var pending = [(source, known)]
        while let (fields, expected) = pending.popLast() {
            guard Set(fields.keys) == Set(expected.keys) else {
                throw NateError.message("搜索用户偏好包含未知或不完整字段，原归档保留。")
            }
            for key in fields.keys {
                if let object = fields[key] as? [String: Any], let template = expected[key] as? [String: Any]
                {
                    pending.append((object, template))
                }
            }
        }
        return value
    }

    /// 业务作用：可迁移偏好必须可完整解释，不能借配置导入携带查询、历史或第二套全局词规则。
    /// 参数说明: 无。
    /// 返回：已知格式、空原文、默认占位词规则和有效容量、字体、呈现参数通过，否则整份拒绝。
    public func validate() throws {
        guard format == 1, options.query.isEmpty, options.replacement.isEmpty,
            options.wordBoundaries == WordBoundarySettings(),
            options.maxMatches == SearchOptions().maxMatches,
            options.stepLimit == SearchOptions().stepLimit
        else {
            throw NateError.message("搜索用户偏好格式、独立规则或资源边界无效，未采用部分设置。")
        }
        try presentation.validate()
        try inputFont.validate()
    }

    /// 业务作用：只发布搜索行为偏好，当前查询、替换原文、目标目录、历史与全局词规则保持自己的来源。
    /// 参数说明:
    /// - state: 当前用户正在使用或已经恢复的完整搜索状态。
    /// 返回：合并后的完整状态，不发起搜索、文件读取或正文编辑。
    public func applying(to state: SearchWindowState) -> SearchWindowState {
        var result = state
        result.options = options
        result.options.query = state.options.query
        result.options.replacement = state.options.replacement
        result.options.wordBoundaries = state.options.wordBoundaries
        result.options.maxMatches = state.options.maxMatches
        result.options.stepLimit = state.options.stepLimit
        result.stayAfterReplace = stayAfterReplace
        result.confirmsOpenReplacement = confirmsOpenReplacement
        result.presentation = presentation
        result.inputFont = inputFont
        result.results = results
        result.marking = marking
        result.styling = styling
        return result
    }
}
