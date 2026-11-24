import Foundation

enum BashHighlightNumbers {
    /// 业务作用：区分连续数值、显式进制错误与 Shell 中以数字起始的普通文件名。
    /// 参数说明:
    /// - bytes: 当前原物理行字节，不含行尾。
    /// - start: 已确认的 ASCII 数字起点。
    /// - arithmetic: 是否在算术上下文，算术操作符与标识符有独立边界。
    /// - budget: 当前物理行和全部词元共用的扫描额度。
    /// 返回：经完整判定的字节终点与明确样式，容量或取消时整体抛错。
    static func scan(
        _ bytes: ArraySlice<UInt8>,
        from start: Int,
        arithmetic: Bool,
        budget: inout ANSILexingBudget
    ) throws -> (end: Int, style: BashHighlightStyle) {
        var end = start
        var radix: Int?
        if bytes[start] == 48, start + 1 < bytes.endIndex, [88, 120].contains(bytes[start + 1]) {
            end = start + 2
            while end < bytes.endIndex, digit(bytes[end], insensitive: true) < 16 {
                try budget.consume()
                end += 1
            }
        }
        else {
            var base = 0
            while end < bytes.endIndex && decimal(bytes[end]) {
                try budget.consume()
                base = min(65, base * 10 + Int(bytes[end] - 48))
                end += 1
            }
            if end < bytes.endIndex, bytes[end] == 35 {
                // 显式进制仅从一至两位原数字取得资格，原生编辑状态仍分类零和一。
                guard base <= 64, end - start <= 2 else {
                    return (end, .error)
                }
                radix = base
                end += 1
                while end < bytes.endIndex, digit(bytes[end], insensitive: base <= 36) < base {
                    try budget.consume()
                    end += 1
                }
                if end < bytes.endIndex, decimal(bytes[end]) {
                    while end < bytes.endIndex && decimal(bytes[end]) {
                        try budget.consume()
                        end += 1
                    }
                    return (end, .error)
                }
            }
        }
        if end < bytes.endIndex {
            let next = bytes[end]
            let ordinaryWord =
                wordStart(next) || decimal(next)
                || next == 64 && radix.map({ $0 <= 36 }) == true
                || (!arithmetic
                    && (next == 45 || next == 46 && (end + 1 == bytes.endIndex || bytes[end + 1] != 46)))
            if ordinaryWord {
                end += 1
                while end < bytes.endIndex {
                    try budget.consume()
                    let byte = bytes[end]
                    guard wordByte(byte, arithmetic: arithmetic) || arithmetic && decimal(byte) else {
                        break
                    }
                    end += 1
                }
                return (end, .identifier)
            }
        }
        return (end, .number)
    }

    /// 业务作用：固定 Bash 进制字母表，较小进制按同一字母值解释大小写。
    /// 参数说明:
    /// - byte: 当前原始 ASCII 候选。
    /// - insensitive: 是否使用不区分大小写的进制字母表。
    /// 返回：进制数值，缺少数字资格时返回 64。
    private static func digit(_ byte: UInt8, insensitive: Bool) -> Int {
        switch byte {
        case 48...57: Int(byte - 48)
        case 97...122: Int(byte - 97) + 10
        case 65...90: Int(byte - 65) + (insensitive ? 10 : 36)
        case 64: 62
        case 95: 63
        default: 64
        }
    }

    /// 业务作用：限定 Bash 十进制原始数字，Unicode 数字保留为文档内容。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 十进制数字时为真。
    static func decimal(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：按 Bash 原生标识符起点分类，不将文件名中的 Unicode 候选当 Shell 名字。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 字母或下划线可开启标识符。
    static func wordStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：按命令和算术上下文分别判定标识符延续。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// - arithmetic: 是否在算术表达式中。
    /// 返回：可作为当前位置标识符字节时为真。
    static func wordByte(_ byte: UInt8, arithmetic: Bool) -> Bool {
        wordStart(byte) || !arithmetic && (decimal(byte) || [43, 45, 46].contains(byte))
    }
}
