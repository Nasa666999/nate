import Foundation
import NateCore

extension CMakeScanner {
    /// 业务作用：CMake 原生名称只采用 ASCII 字母、数字、点及下划线，UTF-8 仍按原字节保留。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：该字节可以继续原生命名候选时为真。
    static func name(_ byte: UInt8) -> Bool {
        byte == 46 || byte == 95 || digit(byte) || byte >= 65 && byte <= 90
            || byte >= 97 && byte <= 122
    }

    /// 业务作用：原生简单数字只接纳 ASCII 十进制数字，不扩展数值语法。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：零至九时为真。
    static func digit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// 业务作用：CMake 候选按特殊控制词、命令、参数、用户项、变量及简单数字的原生顺序取得类别。
    /// 参数说明:
    /// - end: 当前候选包含在内的原字节末端。
    /// 返回：完整候选的原生类别，所有读取及词表比较共用截止和步骤额度。
    mutating func classify(until end: Int) throws -> UInt8 {
        let upper = min(bytes.count, max(emitted, min(end + 1, emitted + 99)))
        var raw: [UInt8] = []
        for index in emitted..<upper {
            try budget.consume()
            raw.append(bytes[index])
        }
        let word = Data(
            raw.prefix(while: {
                $0 != 0
            })
        )
        let lowered = Data(
            word.map {
                $0 >= 65 && $0 <= 90 ? $0 + 32 : $0
            }
        )
        for (names, style) in [
            (["macro", "endmacro"], UInt8(12)),
            (["if", "endif", "elseif", "else"], UInt8(11)),
            (["while", "endwhile"], UInt8(9)),
            (["foreach", "endforeach"], UInt8(10)),
        ] {
            try budget.consume()
            if names.contains(String(decoding: lowered, as: UTF8.self)) {
                return style
            }
        }
        if try rules.contains(lowered, group: 0, budget: &budget) {
            return 5
        }
        if try rules.contains(word, group: 1, budget: &budget) {
            return 6
        }
        if try rules.contains(word, group: 2, budget: &budget) {
            return 8
        }
        if word.count > 3, word[word.startIndex + 1] == 123, word.last == 125 {
            return 7
        }
        if let first = raw.first, Self.digit(first) {
            for byte in raw.dropFirst() {
                try budget.consume()
                if !Self.digit(byte) {
                    return 0
                }
            }
            return 14
        }
        return 0
    }
}
