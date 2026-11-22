import Foundation
import NateCore
import NateSearch
import NateStorage
import NateUI

enum UserConfigurationSchema {
    static let booleanKeys: Set<String> = [
        "autosaveEnabled", "completion.enabled", "completion.words", "completion.language",
        "completion.tab", "completion.enter", "copyLineWithoutSelection", "adaptClipboardLineEndings",
        "incrementalSearch.caseSensitive", "incrementalSearch.wholeWord", "incrementalSearch.highlightAll",
        "incrementalSearch.wrap", "structure.sortByName", "wrapLines", "showSymbols",
    ]
    static let dataLimits: [String: Int] = [
        "editorDisplaySettings": 4096,
        "languageTabSettings": 524_288,
        "documentTabLayout": 1024,
        "indentationSettings": 1024,
        "pairInsertionSettings": 32_768,
        "wordBoundarySettings": 4096,
        "delimiterSelectionSettings": 4096,
        "dateTimeSettings": 4096,
        "fileOpeningSettings": 131_072,
        "webSearchSettings": 32_768,
        "printSettings": 65_536,
        "hexConversionOptions": 4096,
        "selectedTextHighlightOptions": 65_536,
        "multipleSelectionOptions": 4096,
        "saveBackupPolicy": 8192,
        "searchUserPreferences": 65_536,
    ]
    static let keys = booleanKeys.union(dataLimits.keys).union(["completion.threshold", "fontSize"]).sorted()

    /// 业务作用：应用只接受完整且明确的配置字段集合，未知或遗漏字段不能产生部分导入。
    /// 参数说明:
    /// - configuration: 已完成容器摘要和原始类型检查的完整字段集合。
    /// - permit: 当前整份语义校验仍有执行资格。
    /// 返回：全部已知字段及语义有效时通过，任何字段失败均不授予发布权限。
    static func validate(
        _ configuration: UserConfiguration,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard configuration.entries.map(\.key) == keys else {
            throw NateError.message("用户配置字段集合不受支持，未采用部分设置。")
        }
        for entry in configuration.entries {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("用户配置语义校验已取消或超过五秒。")
            }
            try validate(entry, permit: permit)
        }
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("用户配置语义校验已取消或超过五秒。")
        }
    }

    /// 业务作用：配置类型与当前实际读取约束保持一致，归档中字节不能绕过偏好模型的完整校验。
    /// 参数说明:
    /// - entry: 当前已通过容器格式门禁的单项配置。
    /// - permit: 当前完整字段仍有校验资格。
    /// 返回：已知键及完整合法值通过，未知键、错误类型或非法参数整体拒绝。
    static func validate(
        _ entry: UserPreferenceEntry,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard keys.contains(entry.key) else {
            throw UserConfigurationArchiveError.unsupportedFormat
        }
        if case .unset = entry.value {
            guard entry.key != "searchUserPreferences" else {
                throw NateError.message("用户配置必须包含完整搜索行为快照，不能省略后沿用另一份归档。")
            }
            return
        }
        if booleanKeys.contains(entry.key) {
            guard case .boolean = entry.value else {
                throw NateError.message("用户配置布尔字段类型不匹配：" + entry.key)
            }
            return
        }
        if entry.key == "completion.threshold" {
            guard case .integer(let value) = entry.value, (1...20).contains(value) else {
                throw NateError.message("补全起始长度须为 1–20 的整数。")
            }
            return
        }
        if entry.key == "fontSize" {
            let size: Double
            switch entry.value {
            case .integer(let value): size = Double(value)
            case .decimal(let value): size = value
            default: throw NateError.message("既有字号配置不是完整数值。")
            }
            guard size.isFinite, size == 0 || (7...72).contains(size) else {
                throw NateError.message("既有字号须为 7–72 点，零表示采用默认值。")
            }
            return
        }
        guard case .bytes(let data) = entry.value, let limit = dataLimits[entry.key], data.count <= limit
        else {
            throw NateError.message("用户配置不是完整受限归档：" + entry.key)
        }
        try UserConfigurationJSON.validate(data, permit: permit)
        switch entry.key {
        case "editorDisplaySettings":
            _ = try JSONDecoder().decode(EditorDisplaySettings.self, from: data)
        case "languageTabSettings":
            _ = try payload(LanguageTabSettings.self, from: data, field: "settings")
        case "documentTabLayout":
            _ = try payload(DocumentTabLayout.self, from: data, field: "layout")
        case "indentationSettings":
            _ = try payload(IndentationSettings.self, from: data, field: "settings")
        case "pairInsertionSettings":
            _ = try payload(PairInsertionSettings.self, from: data, field: "settings")
        case "wordBoundarySettings":
            _ = try payload(WordBoundarySettings.self, from: data, field: "settings")
        case "delimiterSelectionSettings":
            _ = try payload(DelimiterSelectionSettings.self, from: data, field: "settings")
        case "dateTimeSettings":
            _ = try payload(DateTimeSettings.self, from: data, field: "settings")
        case "fileOpeningSettings":
            _ = try payload(FileOpeningSettings.self, from: data, field: "settings")
        case "webSearchSettings":
            _ = try payload(WebSearchSettings.self, from: data, field: "settings")
        case "printSettings":
            _ = try payload(PrintSettings.self, from: data, field: "settings")
        case "hexConversionOptions":
            let options = try payload(HexEncodingOptions.self, from: data, field: "options")
            guard (0...4096).contains(options.bytesPerLine) else {
                throw NateError.message("HEX 每行原字节数须为 0–4096。")
            }
        case "selectedTextHighlightOptions":
            _ = try JSONDecoder().decode(SelectedTextHighlightOptions.self, from: data)
        case "multipleSelectionOptions":
            _ = try JSONDecoder().decode(MultipleSelectionOptions.self, from: data)
        case "saveBackupPolicy":
            try payload(SaveBackupPolicy.self, from: data, field: "policy").validate()
        case "searchUserPreferences":
            _ = try SearchUserPreferences.decode(data)
        default:
            throw UserConfigurationArchiveError.unsupportedFormat
        }
    }

    /// 业务作用：独立偏好归档必须完整包含格式和指定字段，未知外层字段不能被静默丢弃。
    /// 参数说明:
    /// - type: 当前配置字段对应的业务模型。
    /// - data: 已经过所属键容量检查的完整 JSON 原文。
    /// - field: 归档中明确承载该模型的固定键。
    /// 返回：已知格式的完整模型，外层不完整、未来格式或业务字段非法时整体失败。
    static func payload<T: Decodable>(_ type: T.Type, from data: Data, field: String) throws -> T {
        let format = try JSONDecoder().decode(ConfigurationFormat.self, from: data)
        guard format.format == 1, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(fields.keys) == ["format", field], let value = fields[field]
        else {
            throw UserConfigurationArchiveError.unsupportedFormat
        }
        let body = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: body)
    }
}

private struct ConfigurationFormat: Decodable {
    let format: Int
}
