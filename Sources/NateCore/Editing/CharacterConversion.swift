import Foundation

public enum CharacterConversionField: String, Sendable, CaseIterable {
    case character
    case decimal
    case hexadecimal
    case octal
    case binary

    public var title: String {
        switch self {
        case .character: return "Unicode 字符"
        case .decimal: return "十进制"
        case .hexadecimal: return "十六进制"
        case .octal: return "八进制"
        case .binary: return "二进制"
        }
    }

    var radix: Int? {
        switch self {
        case .character: return nil
        case .decimal: return 10
        case .hexadecimal: return 16
        case .octal: return 8
        case .binary: return 2
        }
    }
}

public struct CharacterConversion: Sendable, Equatable {
    public let value: UInt32

    public var character: String? {
        Unicode.Scalar(value).map {
            String($0)
        }
    }

    /// 业务作用：数值域保留完整 UInt32，超出 Unicode 标量范围时仍可进行数值进制互转。
    /// 参数说明:
    /// - value: 完整无符号三十二位数值。
    /// 返回：固定数值，不把代理项或越界数值替换为其它字符。
    public init(value: UInt32) {
        self.value = value
    }

    /// 业务作用：从明确字符或进制字段解析全部输入，不以截断、符号转换或忽略尾部获得其它数值。
    /// 参数说明:
    /// - input: 原字段文字，不自动去除空白、正负号或进制前缀。
    /// - field: 用户正在编辑的字符或数值进制。
    /// 返回：单个 Unicode 标量或合法 UInt32；空输入、非法数字、多标量及溢出整体失败。
    public init(input: String, field: CharacterConversionField) throws {
        guard !input.isEmpty, input.utf8.prefix(65).count <= 64 else {
            throw NateError.message("转换输入不能为空，且最多包含 64 个 UTF-8 字节。")
        }
        guard let radix = field.radix else {
            let scalars = input.unicodeScalars
            guard let scalar = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex
            else {
                throw NateError.message("字符字段需要一个 Unicode 标量；组合字符请分别转换各标量。")
            }
            value = scalar.value
            return
        }
        for byte in input.utf8 {
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...70: digit = Int(byte - 65) + 10
            case 97...102: digit = Int(byte - 97) + 10
            default: throw NateError.message("数值字段只接受对应进制的 ASCII 数字，不包含空白、符号或前缀。")
            }
            guard digit < radix else {
                throw NateError.message("数值包含不属于当前进制的数字。")
            }
        }
        guard let parsed = UInt32(input, radix: radix) else {
            throw NateError.message("数值超过 UInt32 范围 0 至 4294967295。")
        }
        value = parsed
    }

    /// 业务作用：从同一数值生成各字段，不将任意 UInt32 冒充可插入的 Unicode 字符。
    /// 参数说明:
    /// - field: 需要展示、复制或插入的字段。
    /// 返回：完整数字或实际单标量字符；非法 Unicode 数值的字符字段为空。
    public func representation(for field: CharacterConversionField) -> String? {
        guard let radix = field.radix else {
            return character
        }
        return String(value, radix: radix, uppercase: field == .hexadecimal)
    }
}
