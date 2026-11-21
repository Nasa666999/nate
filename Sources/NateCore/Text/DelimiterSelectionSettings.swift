import Foundation

public struct DelimiterSelectionSettings: Sendable, Codable, Equatable {
    public let opening: String
    public let closing: String
    public let entireDocument: Bool

    private enum CodingKeys: String, CodingKey {
        case opening
        case closing
        case entireDocument
    }

    /// 业务作用：默认分隔符选择只在当前物理行查找圆括号内部。
    /// 参数说明: 无。
    /// 返回：与正文语言和语法括号分析独立的默认配置。
    public init() {
        opening = "("
        closing = ")"
        entireDocument = false
    }

    /// 业务作用：完整验证两端的原始标量，避免多字符或行结束符隐式变成另一套选择规则。
    /// 参数说明:
    /// - opening: 单个 Unicode 标量的左分隔符，不解释转义。
    /// - closing: 单个 Unicode 标量的右分隔符，允许与左侧相同。
    /// - entireDocument: 是否从当前行扩展为全文查找。
    /// 返回：两端合法时建立配置；空值、多标量、NUL 或行段结束符整体拒绝。
    public init(opening: String, closing: String, entireDocument: Bool) throws {
        for value in [opening, closing] {
            guard value.utf8.count <= 4, value.unicodeScalars.count == 1,
                let scalar = value.unicodeScalars.first,
                ![0, 10, 13, 0x85, 0x2028, 0x2029].contains(scalar.value)
            else {
                throw NateError.message("每端必须是一个 Unicode 标量，不能包含 NUL 或行段结束符。")
            }
        }
        self.opening = opening
        self.closing = closing
        self.entireDocument = entireDocument
    }

    /// 业务作用：归档恢复仍执行完整字符约束，损坏配置不取得选择权限。
    /// 参数说明:
    /// - decoder: 完整分隔符规则归档。
    /// 返回：全部必填字段有效时恢复，缺失或非法字段整体失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            opening: values.decode(String.self, forKey: .opening),
            closing: values.decode(String.self, forKey: .closing),
            entireDocument: values.decode(Bool.self, forKey: .entireDocument)
        )
    }

    /// 业务作用：按原始标量编码确认规则来源，规范等价但字符值不同的符号不能共享选择权限。
    /// 参数说明:
    /// - lhs: 已固定的完整规则。
    /// - rhs: 需要复验的当前规则。
    /// 返回：两端 UTF-8 编码和范围开关完全一致时为真。
    public static func == (lhs: DelimiterSelectionSettings, rhs: DelimiterSelectionSettings) -> Bool {
        lhs.entireDocument == rhs.entireDocument
            && lhs.opening.utf8.elementsEqual(rhs.opening.utf8)
            && lhs.closing.utf8.elementsEqual(rhs.closing.utf8)
    }
}
