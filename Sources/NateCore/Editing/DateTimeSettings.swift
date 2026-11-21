import Foundation

public enum DateTimeInsertionMode: Sendable {
    case short
    case long
    case custom
}

public struct DateTimeSettings: Sendable, Codable, Equatable {
    public let format: String
    public let dateFirst: Bool
    let fields: [DateTimeField]

    private enum CodingKeys: String, CodingKey {
        case format
        case dateFirst
    }

    /// 业务作用：自定义日期时间默认使用明确年月日和二十四小时，短长格式默认先时间后日期。
    /// 参数说明: 无。
    /// 返回：保留兼容字段含义的完整默认配置。
    public init() {
        format = "yyyy-MM-dd HH:mm:ss"
        dateFirst = false
        fields = [
            .field(.year, 4), .literal("-"), .field(.month, 2), .literal("-"), .field(.day, 2),
            .literal(" "), .field(.hour24, 2), .literal(":"), .field(.minute, 2), .literal(":"),
            .field(.second, 2),
        ]
    }

    /// 业务作用：完整解析日期时间草稿，非法格式不能导致插入空串而删除原选择。
    /// 参数说明:
    /// - format: 最多 256 个 UTF-16 单元及 1024 UTF-8 字节的原始格式。
    /// - dateFirst: 短长日期时间是否先日期后时间，自定义格式保持原次序。
    /// 返回：非空且引号成对时保存原格式与解析字段；NUL、控制字符和容量不足整体拒绝。
    public init(format: String, dateFirst: Bool) throws {
        guard !format.isEmpty, format.utf8.count <= 1024, format.utf16.count <= 256,
            !format.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || [0x2028, 0x2029].contains($0.value)
            })
        else {
            throw NateError.message("日期时间格式不能为空，最多 256 个 UTF-16 单元和 1024 UTF-8 字节，不能包含控制或行段结束符。")
        }
        self.fields = try DateTimeField.parse(format)
        self.format = format
        self.dateFirst = dateFirst
    }

    /// 业务作用：恢复归档时重新解析全部格式，外部字段不能绕过草稿约束。
    /// 参数说明:
    /// - decoder: 完整日期时间配置归档。
    /// 返回：必填字段完整有效时恢复，否则整体失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            format: values.decode(String.self, forKey: .format),
            dateFirst: values.decode(Bool.self, forKey: .dateFirst)
        )
    }

    /// 业务作用：草稿身份按原编码区分，规范等价文字不能覆盖另一份格式来源。
    /// 参数说明:
    /// - lhs: 打开表单时固定的完整配置。
    /// - rhs: 当前需要复验的配置。
    /// 返回：原始格式 UTF-8 及次序开关完全相同时为真。
    public static func == (lhs: DateTimeSettings, rhs: DateTimeSettings) -> Bool {
        lhs.dateFirst == rhs.dateFirst && lhs.format.utf8.elementsEqual(rhs.format.utf8)
    }
}

enum DateTimeField: Sendable {
    case literal(String)
    case field(DateTimeFieldKind, Int)

    /// 业务作用：只解释明确的日期时间字段，字面文字不会在时间展开后再次被解析为日期字段。
    /// 参数说明:
    /// - format: 已验证容量和控制字符的完整格式。
    /// 返回：保持原顺序的字段及字面文字；单引号不闭合时拒绝。
    static func parse(_ format: String) throws -> [DateTimeField] {
        let scalars = Array(format.unicodeScalars)
        var result: [DateTimeField] = []
        var literal = ""
        var quoted = false
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 39 {
                if index + 1 < scalars.count, scalars[index + 1].value == 39 {
                    literal.append("'")
                    index += 2
                    continue
                }
                quoted.toggle()
            }
            else if !quoted, let kind = DateTimeFieldKind(rawValue: value) {
                if !literal.isEmpty {
                    result.append(.literal(literal))
                    literal = ""
                }
                var end = index + 1
                while end < scalars.count, scalars[end].value == value {
                    end += 1
                }
                result.append(.field(kind, end - index))
                index = end
                continue
            }
            else {
                literal.unicodeScalars.append(scalars[index])
            }
            index += 1
        }
        guard !quoted else {
            throw NateError.message("日期时间格式中的单引号必须闭合；两个连续单引号表示字面单引号。")
        }
        if !literal.isEmpty {
            result.append(.literal(literal))
        }
        return result
    }
}

enum DateTimeFieldKind: UInt32, Sendable {
    case day = 100
    case month = 77
    case year = 121
    case era = 103
    case hour12 = 104
    case hour24 = 72
    case minute = 109
    case second = 115
    case period = 116
}
