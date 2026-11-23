import Foundation

struct EditorThemeCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    /// 业务作用：主题字段在强类型解码前保留原名，未知字段不能被静默舍弃。
    /// 参数说明:
    /// - stringValue: 原归档的对象字段名。
    /// 返回：可供完整字段集合校验使用的键。
    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// 业务作用：主题对象只使用名称字段，不接受整数键冒充样式名称。
    /// 参数说明:
    /// - intValue: 解码器提供的整数键。
    /// 返回：始终拒绝整数对象键。
    init?(intValue: Int) {
        return nil
    }

    /// 业务作用：完整主题协议不忽略未知字段，避免文件被部分解释后覆盖现有配置。
    /// 参数说明:
    /// - decoder: 当前对象的解码来源。
    /// - allowed: 此对象明确支持的全部字段名。
    /// 返回：字段集合完全受支持时通过，否则拒绝当前完整主题。
    static func validate(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard
            values.allKeys.allSatisfy({
                allowed.contains($0.stringValue)
            })
        else {
            throw NateError.message("主题包含无法识别的字段，未采用部分内容。")
        }
    }
}
