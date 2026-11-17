import Foundation
import NateCore

public struct SearchInputFont: Codable, Sendable {
    public var family = "Menlo"
    public var pointSize = 13.0

    /// 业务作用：为查找输入和全文编辑建立独立字体配置，不继承正文视图的缩放。
    /// 参数说明: 无。
    /// 返回：Menlo、13 点的输入字体偏好。
    public init() {}

    /// 业务作用：在字体系统查询和窗口布局前限定名称与字号，非有限数值不能进入几何计算。
    /// 参数说明: 无。
    /// 返回：非空且不含 NUL、CR、LF 的至多 256 字节字体名、7 至 32 点有限字号通过，否则保留原配置。
    public func validate() throws {
        guard family.utf8.count <= 256,
            !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !family.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }),
            pointSize.isFinite, (7...32).contains(pointSize)
        else {
            throw NateError.message("输入字体名称须有效且不超过 256 字节，字号须为 7–32 的有限数值。")
        }
    }
}
