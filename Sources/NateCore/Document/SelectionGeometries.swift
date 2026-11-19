import Foundation

public struct SelectionGeometries: Sendable, Codable {
    public static let maximumCount = 100_000
    public let values: [TextSelection]

    /// 业务作用：为不含稳定身份的兼容选择数组提供同一容量门禁，不在存储层先构建超量选择。
    /// 参数说明:
    /// - values: 尚未与实际正文绑定的完整几何，允许旧记录为空。
    /// 返回：最多十万项的原顺序与方向；超量时失败，实际边界由所属正文另行校验。
    public init(_ values: [TextSelection]) throws {
        guard values.count <= Self.maximumCount else {
            throw NateError.message("选择几何超过十万项，未载入部分选择。")
        }
        self.values = values
    }

    /// 业务作用：读取旧式数组时先检查声明数量，并在逐项解码期间继续执行相同门禁。
    /// 参数说明:
    /// - decoder: 所属有界存储提供的解码器。
    /// 返回：不超过十万项的完整几何；超量、取消、截断或超时不返回部分内容。
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard
            container.count.map({
                $0 <= Self.maximumCount
            }) ?? true
        else {
            throw NateError.message("选择几何超过十万项，原记录保留。")
        }
        let budget = SelectionPreparationBudget(permit: {
            true
        })
        var values: [TextSelection] = []
        while !container.isAtEnd {
            if values.count & 255 == 0 {
                try budget.check()
            }
            guard values.count < Self.maximumCount else {
                throw NateError.message("选择几何超过十万项，原记录保留。")
            }
            values.append(try container.decode(TextSelection.self))
        }
        try budget.check()
        try self.init(values)
    }

    /// 业务作用：兼容数组仍保存原半开坐标和方向，不引入另一份选择身份或改变正文。
    /// 参数说明:
    /// - encoder: 所属恢复或会话提供的编码器。
    /// 返回：完整原顺序数组；取消、超时或编码失败不提供部分记录。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        let budget = SelectionPreparationBudget(permit: {
            true
        })
        for (index, value) in values.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            try container.encode(value)
        }
        try budget.check()
    }
}
