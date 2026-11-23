import Foundation
import NateCore

extension PascalFoldScanner {
    /// 业务作用：折叠前瞻只沿当前完整原文读取，文件边缘不产生可匹配的字母或结束符。
    /// 参数说明:
    /// - position: 全文固定字节坐标。
    /// 返回：实际原字节，真实范围外为 NUL 哨兵。
    func byte(_ position: Int) -> UInt8 {
        position >= 0 && position < bytes.count ? bytes[position] : 0
    }

    /// 业务作用：仅完整词法分类授予折叠资格，正文范围外不能冒用相邻类别。
    /// 参数说明:
    /// - position: 全文固定字节坐标。
    /// 返回：实际已确认类别，范围外为普通正文。
    func styleAt(_ position: Int) -> UInt8 {
        position >= 0 && position < styles.count ? styles[position] : 0
    }

    /// 业务作用：Pascal 两类流式注释可以跳过声明间空白，预处理与行注释不取得同样资格。
    /// 参数说明:
    /// - style: 完整原生词法类别。
    /// 返回：花括号或圆括号星号普通注释为真。
    func stream(_ style: UInt8) -> Bool {
        style == 2 || style == 3
    }

    /// 业务作用：声明前瞻保持原生 ASCII 名称边界，Unicode 字母不被额外接受为类方法关键字。
    /// 参数说明:
    /// - byte: 真实前瞻字节。
    /// 返回：ASCII 字母或下划线为真。
    func asciiWordStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：固定指令或声明关键字按原生截取长度读取，不把更长未知名称的前缀误当已知指令。
    /// 参数说明:
    /// - start: 已确认名称的实际起点。
    /// - maximum: 原生目标缓冲区可保留的最大原字节数。
    /// - digits: 类方法前瞻允许数字和下划线，预处理指令只允许 ASCII 字母。
    /// 返回：有界 ASCII 小写候选，共同预算不足时拒绝。
    mutating func forwardWord(at start: Int, maximum: Int, digits: Bool) throws -> String {
        var output: [UInt8] = []
        var position = start
        while output.count < maximum {
            try budget.consume()
            let value = byte(position)
            let allowed =
                (65...90).contains(value) || (97...122).contains(value)
                || digits && (value == 95 || PascalCharacters.digit(value))
            if !allowed {
                break
            }
            output.append(PascalCharacters.folded(value))
            position += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// 业务作用：前向声明跳过完整原文中的空白和已确认流式注释，父类简写可额外跳过 ASCII 名称。
    /// 参数说明:
    /// - position: 本次前瞻起点之前的原字节位置。
    /// - includeNames: 是否同时跳过父类名称字符。
    /// 返回：第一个未经跳过的实际位置，或真实 EOF；超量时不猜测后继声明。
    mutating func skip(after position: Int, includeNames: Bool = false) throws -> Int {
        var index = position + 1
        while index < bytes.count {
            try budget.consume()
            let value = bytes[index]
            let name = includeNames && (asciiWordStart(value) || PascalCharacters.digit(value))
            if value == 9 || value == 32 || value == 13 || value == 10 || stream(styles[index]) || name {
                index += 1
            }
            else {
                break
            }
        }
        return index
    }

    /// 业务作用：连续行注释只接受行首空白后真实的双斜杠，字符串内或代码后的注释不形成整行组。
    /// 参数说明:
    /// - line: 固定原文的真实物理行号。
    /// 返回：行首空白后为已确认行注释时为真，缺席或空行不借邻行成立。
    mutating func commentLine(_ line: Int) throws -> Bool {
        guard line >= 0, line < starts.count else {
            return false
        }
        let start = starts[line]
        let end = (line + 1 < starts.count ? starts[line + 1] : bytes.count) - 1
        var index = start
        while index < end {
            try budget.consume()
            let current = byte(index)
            if current == 47, byte(index + 1) == 47, styleAt(index) == 4 {
                return true
            }
            if current != 9, current != 32 {
                return false
            }
            index += 1
        }
        return false
    }
}
