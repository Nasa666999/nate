import Foundation

public struct WordBoundarySettings: Sendable, Codable, Equatable {
    public let useCustom: Bool
    public let additionalCharacters: String
    private let additional: Set<UInt32>

    private enum CodingKeys: String, CodingKey {
        case useCustom
        case additionalCharacters
    }

    /// 业务作用：默认词边界采用固定 Unicode 分类，不因打开文档或读取偏好改变正文。
    /// 参数说明: 无。
    /// 返回：尚未启用附加字符的默认规则。
    public init() {
        useCustom = false
        additionalCharacters = ""
        additional = []
    }

    /// 业务作用：附加词字符只改变边界判断，关闭时保留草稿，真实行结束始终保持独立。
    /// 参数说明:
    /// - useCustom: 是否在默认词字符上启用附加集合。
    /// - additionalCharacters: 最多 256 个标量及 1024 UTF-8 字节的原始字符集合。
    /// 返回：整份规则合法时建立；NUL、CR、LF 及 Unicode 行段结束符或容量不足时拒绝。
    public init(useCustom: Bool, additionalCharacters: String) throws {
        guard additionalCharacters.utf8.count <= 1024,
            additionalCharacters.unicodeScalars.count <= 256,
            additionalCharacters.unicodeScalars.allSatisfy({
                ![0, 10, 13, 0x85, 0x2028, 0x2029].contains($0.value)
            })
        else {
            throw NateError.message("附加词字符最多 256 个标量和 1024 UTF-8 字节，不能包含 NUL 或行段结束符。")
        }
        self.useCustom = useCustom
        self.additionalCharacters = additionalCharacters
        additional = Set(additionalCharacters.unicodeScalars.map(\.value))
    }

    /// 业务作用：取词、字面整词搜索和按词导航共用同一标量分类，附加项不替代默认 Unicode 词字符。
    /// 参数说明:
    /// - scalar: 正文中的完整 Unicode 标量值。
    /// 返回：默认字母、数字、组合标记、下划线或已启用的附加字符为真，其它为假。
    public func contains(_ scalar: UInt32) -> Bool {
        UnicodeWordClassification.contains(scalar) || useCustom && additional.contains(scalar)
    }

    /// 业务作用：规则身份按原始 UTF-8 保留，关闭状态下的不同草稿也不能相互冒充同一配置来源。
    /// 参数说明:
    /// - lhs: 已固定的完整词边界规则。
    /// - rhs: 需要复验的当前规则。
    /// 返回：开关和字符原始编码完全一致时为真。
    public static func == (lhs: WordBoundarySettings, rhs: WordBoundarySettings) -> Bool {
        lhs.useCustom == rhs.useCustom
            && lhs.additionalCharacters.utf8.elementsEqual(rhs.additionalCharacters.utf8)
    }

    /// 业务作用：外部配置恢复时重新确认字符预算及行边界，不采用归档中的预计算集合。
    /// 参数说明:
    /// - decoder: 完整词边界配置。
    /// 返回：全部字段合法时恢复原草稿及独立集合，非法配置整体失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            useCustom: values.decode(Bool.self, forKey: .useCustom),
            additionalCharacters: values.decode(String.self, forKey: .additionalCharacters)
        )
    }
}
