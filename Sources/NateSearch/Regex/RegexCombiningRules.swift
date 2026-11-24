import Foundation

enum RegexCombiningRules {
    private static let ranges: [ClosedRange<UInt16>] = [
        0x0300...0x0361,
        0x0483...0x0486,
        0x0903...0x0903,
        0x093E...0x0940,
        0x0949...0x094C,
        0x0982...0x0983,
        0x09BE...0x09C0,
        0x09C7...0x09CC,
        0x09D7...0x09D7,
        0x0A3E...0x0A40,
        0x0A83...0x0A83,
        0x0ABE...0x0AC0,
        0x0AC9...0x0ACC,
        0x0B02...0x0B03,
        0x0B3E...0x0B3E,
        0x0B40...0x0B40,
        0x0B47...0x0B4C,
        0x0B57...0x0B57,
        0x0B83...0x0B83,
        0x0BBE...0x0BBF,
        0x0BC1...0x0BCC,
        0x0BD7...0x0BD7,
        0x0C01...0x0C03,
        0x0C41...0x0C44,
        0x0C82...0x0C83,
        0x0CBE...0x0CBE,
        0x0CC0...0x0CC4,
        0x0CC7...0x0CCB,
        0x0CD5...0x0CD6,
        0x0D02...0x0D03,
        0x0D3E...0x0D40,
        0x0D46...0x0D4C,
        0x0D57...0x0D57,
        0x0F7F...0x0F7F,
        0x20D0...0x20E1,
        0x3099...0x309A,
        0xFE20...0xFE23,
        0xFFFF...0xFFFF,
    ]

    /// 业务作用：固定 Boost 在 Windows 宽字符匹配中的组合范围，不把正则单元替换为系统字形簇规则。
    /// 参数说明:
    /// - unit: 当前原文的单个 UTF-16 单元。
    /// 返回：该单元属于固定组合范围时为真，包括原范围表中的 U+FFFF。
    static func contains(_ unit: UInt16) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound < unit {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower < ranges.count && ranges[lower].contains(unit)
    }
}
