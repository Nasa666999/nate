import Foundation

public enum MarkupDialect: Sendable {
    case html
    case xml
}

enum MarkupNames {
    /// 业务作用：HTML 属性名与 XML Name 分别验证，模板属性不会因采用 XML 首字符限制而失去标签上下文。
    /// 参数说明:
    /// - bytes: 已由真实空白、赋值或结束符界定的完整属性名。
    /// - dialect: 当前固定的标记方言。
    /// 返回：名称满足相应词法边界时为真，不解释属性值或执行模板表达式。
    static func attributeValidated(_ bytes: [UInt8], dialect: MarkupDialect) -> Bool {
        if dialect == .xml {
            return validated(bytes, dialect: .xml) != nil
        }
        guard !bytes.isEmpty, bytes.count <= 4096, String(bytes: bytes, encoding: .utf8) != nil else {
            return false
        }
        return bytes.allSatisfy {
            ![0, 9, 10, 12, 13, 32, 34, 39, 47, 60, 61, 62].contains($0)
        }
    }

    /// 业务作用：名称按固定 XML 字符范围验证，HTML 开端另要求 ASCII 字母，不依赖系统字符数据库。
    /// 参数说明:
    /// - bytes: 当前完整名称的原始 UTF-8，最多 4096 字节。
    /// - dialect: HTML 或 XML 的明确解释规则。
    /// 返回：名称合法时保留原字节字符串，其它内容不成为可生成的闭合标签。
    static func validated(_ bytes: [UInt8], dialect: MarkupDialect) -> String? {
        guard !bytes.isEmpty, bytes.count <= 4096, let text = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        var first = true
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if first {
                let valid =
                    dialect == .html
                    ? (65...90).contains(value) || (97...122).contains(value) : start(value)
                guard valid else {
                    return nil
                }
                first = false
            }
            else if !start(value) && ![45, 46, 0xb7].contains(value)
                && !(48...57).contains(value) && !(0x300...0x36f).contains(value)
                && !(0x203f...0x2040).contains(value)
            {
                return nil
            }
        }
        return text
    }

    /// 业务作用：标签识别只折叠 ASCII 大写，HTML 名称中的其它原字节保持精确身份。
    /// 参数说明:
    /// - bytes: 已确认的名称或固定 ASCII 标记。
    /// 返回：可用于 HTML void 和原始文本规则查询的稳定字节序列。
    static func folded(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map {
            (65...90).contains($0) ? $0 + 32 : $0
        }
    }

    /// 业务作用：XML 名称首字符采用 XML 1.0 的固定码点区间，冒号保留命名空间原文。
    /// 参数说明:
    /// - value: 当前完整 Unicode 码点。
    /// 返回：属于 NameStartChar 时为真。
    private static func start(_ value: UInt32) -> Bool {
        value == 58 || value == 95 || (65...90).contains(value) || (97...122).contains(value)
            || (0xc0...0xd6).contains(value) || (0xd8...0xf6).contains(value)
            || (0xf8...0x2ff).contains(value) || (0x370...0x37d).contains(value)
            || (0x37f...0x1fff).contains(value) || (0x200c...0x200d).contains(value)
            || (0x2070...0x218f).contains(value) || (0x2c00...0x2fef).contains(value)
            || (0x3001...0xd7ff).contains(value) || (0xf900...0xfdcf).contains(value)
            || (0xfdf0...0xfffd).contains(value) || (0x10000...0xeffff).contains(value)
    }
}
