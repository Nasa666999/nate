import Foundation

public enum EditorThemeCodec {
    /// 业务作用：独立主题文件先确认原字节容量与唯一键，再解释完整样式，不接受部分有效配置。
    /// 参数说明:
    /// - data: 最多 8 MiB 的完整 Nate 主题 JSON。
    /// - permit: 当前来源、应用意图与操作生命周期仍然有效。
    /// 返回：已知格式及全部字段合法的独立主题；取消、重复键或超量整体拒绝。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> EditorThemeDefinition {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < deadline
        }
        try ConfigurationJSONInput.validate(
            data,
            maximumBytes: 8 * 1024 * 1024,
            maximumKeys: 131_072,
            label: "主题",
            permit: allowed
        )
        let value = try JSONDecoder().decode(EditorThemeDefinition.self, from: data)
        try Task.checkCancellation()
        // 完整字段解析后仍须持有同一来源资格，迟到的主题不能替换用户后来选择的配色。
        guard allowed() else {
            throw NateError.message("主题来源或操作资格已经改变，未采用新配置。")
        }
        return value
    }

    /// 业务作用：主题导出使用稳定可读的完整归档，编码完成前不取得替换旧文件的权限。
    /// 参数说明:
    /// - theme: 全部字段已经校验的独立主题。
    /// - permit: 导出意图和所属配置仍有效。
    /// 返回：最多 8 MiB 的完整 UTF-8 JSON；超量、取消或失去资格时拒绝输出。
    public static func encode(
        _ theme: EditorThemeDefinition,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try Task.checkCancellation()
        guard permit() else {
            throw NateError.message("主题导出资格已经改变。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(theme)
        guard data.count < 8 * 1024 * 1024 else {
            throw NateError.message("完整主题归档超过 8 MiB，未输出部分内容。")
        }
        data.append(10)
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("主题导出资格已经改变或超过共同截止。")
        }
        return data
    }
}
