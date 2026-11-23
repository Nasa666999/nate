import Foundation
import NateCore

extension NncronScanner {
    /// 业务作用：原生安全读取在真实文档边缘使用空格哨兵，末尾反斜杠仍依同一注释规则分类。
    /// 参数说明:
    /// - position: 本轮原字节中的相对位置。
    /// 返回：范围内原字节或边缘哨兵。
    func byte(_ position: Int) -> UInt8 {
        position >= 0 && position < bytes.count ? bytes[position] : 32
    }

    /// 业务作用：nnCron 按任务、注释、字符串和环境标记的原生优先级取得当前范围身份。
    /// 参数说明:
    /// - current: 已确认的当前原字节。
    /// 返回：当前字节推进状态或取得明确样式，普通原文保持默认身份。
    mutating func beginState(_ current: UInt8) throws {
        let following = byte(cursor + 1)
        if [10, 13, 9, 32].contains(current) {
            try colour(until: cursor, style: 0)
        }
        else if current == 35 && following == 40 || current == 41 && following == 35 {
            state.mode = 2
            try colour(until: cursor, style: 2)
        }
        else if current == 92 && (following == 32 || following == 9) || current == 35 {
            state.mode = 1
            try colour(until: cursor, style: 1)
        }
        else if current == 34 {
            state.mode = 8
            try colour(until: cursor, style: 8)
        }
        else if current == 37 || current == 60 && following == 37 {
            state.mode = 9
            try colour(until: cursor, style: 9)
        }
        else if current == 42 {
            try colour(until: cursor, style: 6)
        }
        else if NncronCharacters.letter(current) || current == 60 {
            wordStart = cursor
            state.mode = 10
        }
        else if NncronCharacters.digit(current) {
            wordStart = cursor
            state.mode = 7
        }
        else {
            try colour(until: cursor, style: 0)
        }
    }

    /// 业务作用：nnCron 颜色顺序保留环境变量的一字节前向呈现及节分隔符归属，不覆盖已经交付的原字节。
    /// 参数说明:
    /// - end: 原生分支要求覆盖的包含端点，可以触及真实范围后的一个哨兵。
    /// - style: 当前分支授予的完整原生样式。
    /// 返回：仅实际原字节取得样式；未知类别或预算不足拒绝整份分类。
    mutating func colour(until end: Int, style: UInt8) throws {
        guard end >= -1, end <= bytes.count, style <= 10, styles.count == bytes.count else {
            throw NateError.invalidRange
        }
        let last = min(end, bytes.count - 1)
        if last < emitted {
            return
        }
        for index in emitted...last {
            try budget.consume()
            styles[index] = style
        }
        emitted = last + 1
    }
}
