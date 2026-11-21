import Foundation

extension HexRecord {
    /// 业务作用：字段读取只访问当前原始行，缺少的字符按零哨兵解释，不读取其它记录数据。
    /// 参数说明:
    /// - offset: 当前行内的原字节位置。
    /// 返回：可确认的原字节，来源之外为零。
    func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    }

    /// 业务作用：十六进制字段按固定 ASCII 解释，不受系统区域或 Unicode 规范等价影响。
    /// 参数说明:
    /// - value: 原始候选字节。
    /// 返回：合法半字节为零至十五，其它字节为负一。
    static func nibble(_ value: UInt8) -> Int {
        if value >= 48 && value <= 57 {
            return Int(value - 48)
        }
        if value >= 65 && value <= 70 {
            return Int(value - 65 + 10)
        }
        if value >= 97 && value <= 102 {
            return Int(value - 97 + 10)
        }
        return -1
    }

    /// 业务作用：双字符字段必须完整且均为十六进制，截断不静默补齐低半字节。
    /// 参数说明:
    /// - offset: 高半字节的原始位置。
    /// 返回：完整字段为零至二百五十五，否则为负一。
    func pair(_ offset: Int) -> Int {
        let high = Self.nibble(byte(offset))
        let low = Self.nibble(byte(offset + 1))
        return high >= 0 && low >= 0 ? high * 16 + low : -1
    }

    /// 业务作用：各格式声明计数字段只使用自己的偏移，非法计数字面保留零候选而不猜测容量。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：原始声明计数，非法字段为零。
    func byteCount(_ origin: Int) -> Int {
        max(0, pair(origin + (mode == .srec ? 2 : 1)))
    }

    /// 业务作用：按记录格式与类型选择地址宽度，未知 Motorola 类型不消费猜测地址。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：地址字段字节数，未知类型为零。
    func addressSize(_ origin: Int) -> Int {
        guard mode == .srec else {
            return 2
        }
        switch byte(origin + 1) {
        case 48, 49, 53, 57: return 2
        case 50, 54, 56: return 3
        case 51, 55: return 4
        default: return 0
        }
    }

    /// 业务作用：地址字段的数据显示身份依格式区分普通地址、记录总数、起始地址或无地址。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：相应原始样式编号，未知类型使用独立未知字段身份。
    func addressType(_ origin: Int) -> Int {
        if mode == .srec {
            switch byte(origin + 1) {
            case 48: return 6
            case 49, 50, 51: return 7
            case 53, 54: return 8
            case 55, 56, 57: return 9
            default: return 10
            }
        }
        if mode == .tehex {
            return byte(origin + 3) == 54 ? 7 : (byte(origin + 3) == 56 ? 9 : 10)
        }
        switch pair(origin + 7) {
        case 0: return 7
        case 1...5: return 6
        default: return 10
        }
    }

    /// 业务作用：数据字段采用当前格式规定的含义，非数据记录不被强制解释成普通负载。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：交替数据、空数据、扩展地址、起始地址或未知数据的固定样式编号。
    func dataType(_ origin: Int) -> Int {
        if mode == .srec {
            switch byte(origin + 1) {
            case 48...51: return 12
            case 53...57: return 15
            default: return 14
            }
        }
        switch pair(origin + 7) {
        case 0: return 12
        case 1: return 15
        case 2, 4: return 11
        case 3, 5: return 9
        default: return 14
        }
    }

    /// 业务作用：控制记录的负载采用规定宽度，声明错误时校验和仍位于该类型的固定呈现位置。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：相应负载字节数，未知或普通记录按自身计数推导。
    func dataSize(_ origin: Int) -> Int {
        if mode == .srec {
            return (53...57).contains(byte(origin + 1))
                ? 0 : byteCount(origin) - addressSize(origin) - 1
        }
        switch pair(origin + 7) {
        case 1: return 0
        case 2, 4: return 2
        case 3, 5: return 4
        default: return byteCount(origin)
        }
    }

    /// 业务作用：字段位置回看只在当前原始记录内寻找格式标记，所有比较计入共同预算。
    /// 参数说明:
    /// - offset: 当前字段起始位置。
    /// 返回：最近的格式起始标记；找不到时使用当前行首候选。
    mutating func recordStart(at offset: Int) throws -> Int {
        var position = min(offset, bytes.count - 1)
        let marker: UInt8 = mode == .srec ? 83 : 58
        while position > 0, byte(position) != marker {
            try budget.consume()
            position -= 1
        }
        return max(0, position)
    }

    /// 业务作用：记录长度按原始字节直至真实 CR 或 LF 计算，NUL 与其它字符不会被静默丢弃。
    /// 参数说明:
    /// - offset: 需要计数的原字节起点。
    /// 返回：当前物理记录剩余原始字节数。
    mutating func remainingDigits(from offset: Int) throws -> Int {
        var position = max(0, offset)
        while position < bytes.count, byte(position) != 10 && byte(position) != 13 {
            try budget.consume()
            position += 1
        }
        return position - max(0, offset)
    }

    /// 业务作用：计数比较保留未完整校验和的进位规则，不把一个末尾半字节直接视为额外完整负载。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：扣除固定字段后的字节对数量，过短记录可能为负数。
    mutating func countedBytes(_ origin: Int) throws -> Int {
        let count = try remainingDigits(from: origin) - (mode == .srec ? 4 : 11)
        return (count >= 0 ? count + 1 : count) / 2
    }

    /// 业务作用：校验和按格式的原始半字节或字节求和，非法字段明确保留错误身份。
    /// 参数说明:
    /// - origin: 当前记录起始候选位置。
    /// 返回：零至二百五十五的计算值，缺少或非法数字时为负一。
    mutating func checksum(_ origin: Int) throws -> Int {
        var sum = 0
        let count = byteCount(origin)
        if mode == .tehex {
            sum =
                Self.nibble(byte(origin + 1)) + Self.nibble(byte(origin + 2))
                + Self.nibble(byte(origin + 3))
            if count >= 6 {
                for offset in 6...count {
                    try budget.consume()
                    let value = Self.nibble(byte(origin + offset))
                    guard value >= 0 else {
                        return -1
                    }
                    sum += value
                }
            }
            return sum & 255
        }
        let start = origin + (mode == .srec ? 2 : 1)
        let digits = mode == .srec ? count * 2 : 8 + count * 2
        for offset in stride(from: start, to: start + digits, by: 2) {
            try budget.consume()
            let value = pair(offset)
            guard value >= 0 else {
                return -1
            }
            sum += value
        }
        return mode == .srec ? ~sum & 255 : -sum & 255
    }
}
