import Foundation
import NateCore

extension RustLexing {
    /// 业务作用：按固定优先级识别 Rust 前缀，嵌套注释与各类字符串优先于代码符号。
    /// 参数说明: 无。
    /// 返回：整个物理范围分类完成，未闭合字面状态留给下一连续范围。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            if state.depth > 0 {
                try blockComment()
                continue
            }
            if [13, 21, 24].contains(state.style) {
                try stringLiteral()
                continue
            }
            if [14, 22, 25].contains(state.style) {
                try rawLiteral()
                continue
            }
            let start = cursor
            let c = byte(cursor), n = byte(cursor + 1), n2 = byte(cursor + 2)
            if base + cursor == 0, c == 35, n == 33, n2 != 91 {
                try lineComment(style: 2)
            }
            else if [32, 9, 10, 13].contains(c) {
                if c == 10 || c == 13 {
                    state.lineComment = false
                }
                cursor += 1
                try paint(0)
            }
            else if c == 47, n == 47 {
                try lineComment(style: n2 == 33 || n2 == 47 && byte(cursor + 3) != 47 ? 4 : 2)
            }
            else if c == 47, n == 42 {
                state.depth = 1
                state.style = n2 == 33 || n2 == 42 && ![42, 47].contains(byte(cursor + 3)) ? 3 : 1
                cursor += 2
                try blockComment()
            }
            else if c == 114, n == 35, Self.identifierStart(n2) {
                cursor += 2
                let word = cursor
                try identifierEnd()
                let value = String(decoding: bytes[word..<min(cursor, word + 1023)], as: UTF8.self)
                try paint(["crate", "self", "super", "Self"].contains(value) ? 20 : 17)
            }
            else if c == 114, n == 35 || n == 34 {
                try rawStart(style: 14)
            }
            else if [98, 99].contains(c), n == 114, n2 == 35 || n2 == 34 {
                cursor += 1
                try rawStart(style: c == 98 ? 22 : 25)
            }
            else if [98, 99].contains(c), n == 34 {
                state.style = c == 98 ? 21 : 24
                cursor += 2
                try stringLiteral()
            }
            else if c == 98, n == 39 {
                cursor += 1
                try character(asciiOnly: true)
            }
            else if Self.identifierStart(c) {
                try identifierEnd()
                if byte(cursor) == 33 {
                    cursor += 1
                    try paint(19)
                }
                else {
                    let name = Data(bytes[start..<min(cursor, start + 1023)])
                    let group = groups.firstIndex {
                        $0.contains(name)
                    }
                    try paint(
                        group.map {
                            $0 + 6
                        } ?? 17
                    )
                }
            }
            else if Self.digit(c, radix: 10) {
                try number()
            }
            else if Self.operation(c) {
                cursor += 1
                try paint(16)
            }
            else if c == 39 {
                try character(asciiOnly: false)
            }
            else if c == 34 {
                state.style = 13
                cursor += 1
                try stringLiteral()
            }
            else {
                cursor += 1
                try paint(20)
            }
            guard cursor > start else {
                throw NateError.message("Rust 词法无法取得前向边界，未发布部分结果。")
            }
        }
    }

    /// 业务作用：真实原字节与越界零哨兵分别用于词法边界，不改写源 NUL。
    /// 参数说明:
    /// - offset: 相对本物理范围的位置。
    /// 返回：范围内原字节，范围之外为零。
    func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    }

    /// 业务作用：当前词法片段先在独立类别缓冲中封存，任何失败都不能污染正文或旧检查点。
    /// 参数说明:
    /// - style: 当前已完整确认的原生样式编号。
    /// 返回：从未封存起点到当前光标的有界字节取得该类别。
    mutating func paint(_ style: Int) throws {
        while segment < min(cursor, bytes.count) {
            try budget.consume()
            classes[segment] = UInt8(style)
            segment += 1
        }
    }

    /// 业务作用：名称沿原字节边界前进，保留基准对非 ASCII 字节的宽松名称分类。
    /// 参数说明: 无。
    /// 返回：光标位于首个非名称字节，不应用 Unicode 规范化。
    mutating func identifierEnd() throws {
        while Self.identifierContinue(byte(cursor)) {
            try budget.consume()
            cursor += 1
        }
    }

    /// 业务作用：Rust 名称起点按固定 ASCII 字母、下划线及原非 ASCII 字节识别。
    /// 参数说明:
    /// - byte: 当前候选原字节。
    /// 返回：符合基准名称首字节范围时为真。
    static func identifierStart(_ byte: UInt8) -> Bool {
        byte >= 128 || byte == 95 || byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }

    /// 业务作用：名称后继允许 ASCII 数字，其它范围继续沿用原名称起点规则。
    /// 参数说明:
    /// - byte: 当前候选原字节。
    /// 返回：可以属于名称后继时为真。
    static func identifierContinue(_ byte: UInt8) -> Bool {
        identifierStart(byte) || digit(byte, radix: 10)
    }

    /// 业务作用：代码操作符使用固定符号集合，字符串和注释中的相同字节不进入此通道。
    /// 参数说明:
    /// - byte: 当前候选原字节。
    /// 返回：基准定义的 Rust 操作符字节时为真。
    static func operation(_ byte: UInt8) -> Bool {
        ";,(){}[]@#~+*/^%.:!<>=-&|$?".utf8.contains(byte)
    }
}
