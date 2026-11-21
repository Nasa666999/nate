import Foundation

extension LispLexing {
    /// 业务作用：读取原字节证据，不以源 NUL 截断正文，来源之外使用规定空格哨兵。
    /// 参数说明:
    /// - offset: 相对当前范围的位置。
    /// 返回：可确认的原始字节或空格。
    func byte(_ offset: Int) -> UInt8 {
        if offset >= 0, offset < bytes.count {
            return bytes[offset]
        }
        if let snapshot, base + offset >= 0, base + offset < snapshot.text.byteCount {
            return snapshot.text.byte(at: base + offset) ?? 32
        }
        return 32
    }

    /// 业务作用：只有固定读取语法中的括号、引号与反引号具有操作符身份。
    /// 参数说明:
    /// - value: 候选原字节。
    /// 返回：属于固定操作符集合时为真。
    static func operation(_ value: UInt8) -> Bool {
        [39, 96, 40, 41, 91, 93, 123, 125].contains(value)
    }

    /// 业务作用：名称候选采用原有 ASCII 边界，Unicode 和双引号不被并入名称。
    /// 参数说明:
    /// - value: 候选原字节。
    /// 返回：可属于读取名称时为真，源 NUL 仍可进入候选。
    static func word(_ value: UInt8) -> Bool {
        value < 128 && value != 59 && value != 32 && !(9...13).contains(value)
            && value != 34 && !operation(value)
    }

    /// 业务作用：进制读取宏只接受其规定的 ASCII 数位，不对非法尾部进行数值转换。
    /// 参数说明:
    /// - value: 候选原字节。
    /// - radix: 当前明确指定的二、八或十六进制。
    /// 返回：数位在指定进制内时为真。
    static func digit(_ value: UInt8, radix: Int) -> Bool {
        if radix <= 10 {
            return value >= 48 && Int(value) < 48 + radix
        }
        return value >= 48 && value <= 57 || value >= 65 && Int(value) < 55 + radix
            || value >= 97 && Int(value) < 87 + radix
    }

    /// 业务作用：名称结束时以最多九十九个原字节确认函数、第二词表、数值或特殊名称身份。
    /// 参数说明:
    /// - end: 完整名称最后字节。
    /// 返回：名称分类完成，词表匹配保留源 NUL 的读取边界及 ASCII 大小写。
    mutating func classify(_ end: Int) throws {
        var values: [UInt8] = []
        var number = true
        if end >= segment {
            for offset in segment...min(end, segment + 98) {
                try budget.consume()
                let current = byte(offset)
                number = number && (current >= 48 && current <= 57 || current == 46)
                values.append(current)
            }
        }
        let name = String(
            decoding: values.prefix {
                $0 != 0
            },
            as: UTF8.self
        )
        var style = 9
        if number {
            style = 2
        }
        else if keywords.contains(name) {
            style = 3
        }
        else if secondary.contains(name) {
            style = 4
        }
        else if let first = values.first, let last = values.last,
            first == last && (first == 42 || first == 43)
        {
            style = 11
        }
        try paint(end, style)
    }
}
