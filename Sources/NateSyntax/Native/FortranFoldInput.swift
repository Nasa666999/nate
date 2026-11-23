import Foundation
import NateCore

extension FortranFoldScanner {
    /// 业务作用：折叠前瞻使用原生空格哨兵，读取仍受真实文档边缘与共同计算预算约束。
    /// 参数说明:
    /// - position: 当前固定原文中的原字节位置。
    /// 返回：实际原字节或原生空格哨兵；预算不足时拒绝。
    mutating func byte(at position: Int) throws -> UInt8 {
        try budget.consume()
        return bytes.indices.contains(position) ? bytes[position] : 32
    }

    /// 业务作用：括号前瞻只使用当前同源词法分类，文档外没有可借用的样式资格。
    /// 参数说明:
    /// - position: 当前固定原文中的原字节位置。
    /// 返回：实际类别或原生默认类别；预算不足时拒绝。
    mutating func style(at position: Int) throws -> UInt8 {
        try budget.consume()
        return styles.indices.contains(position) ? styles[position] : 0
    }

    /// 业务作用：Fortran 折叠名称采用原生 ASCII 数字、字母、点号和下划线边界。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：原生折叠名称成员时为真。
    static func word(_ value: UInt8) -> Bool {
        FortranCharacters.alphanumeric(UInt32(value)) || value == 46 || value == 95
    }

    /// 业务作用：折叠名称保留原生三十一字节上限及 C 字符串收束，层级判断不读取整个长名称副本。
    /// 参数说明:
    /// - start: 原生记录的名称起点。
    /// - end: 名称的包含式末端。
    /// 返回：当前原文中的有限 ASCII 小写名称；边界或预算不足时拒绝。
    mutating func name(from start: Int, through end: Int) throws -> String {
        guard start >= 0, end >= start, end < bytes.count else {
            throw NateError.invalidRange
        }
        var raw: [UInt8] = []
        for position in start..<min(end + 1, start + 31) {
            let value = try byte(at: position)
            if value == 0 {
                break
            }
            raw.append(FortranCharacters.folded(value))
        }
        return String(decoding: raw, as: UTF8.self)
    }

    /// 业务作用：续行折叠前瞻保留原生位置推进顺序，真实 EOF 不得被空格哨兵解释成无限后继。
    /// 参数说明:
    /// - start: 已确认续行符之后的真实原字节起点。
    /// 返回：原生推进后的后继位置；没有真实后继、预算或截止不足时拒绝整份折叠。
    mutating func continuedPosition(from start: Int) throws -> Int {
        var position = start
        while true {
            // 未取得真实结束符前不允许读取文档外空格，避免有限输入变成无限前瞻。
            guard position < bytes.count else {
                throw NateError.message("Fortran 折叠续行缺少真实物理结束符。")
            }
            let value = try byte(at: position)
            position += 1
            if value == 13 || value == 10 {
                break
            }
        }
        if try byte(at: position) == 10 {
            position += 1
        }
        while true {
            guard position < bytes.count else {
                throw NateError.message("Fortran 折叠续行缺少真实后继。")
            }
            let value = try byte(at: position)
            position += 1
            if !FortranCharacters.blank(UInt32(value)) {
                break
            }
        }
        if try byte(at: position) == 38 {
            repeat {
                position += 1
                guard position < bytes.count else {
                    throw NateError.message("Fortran 折叠续行缺少标记后的真实后继。")
                }
            } while try FortranCharacters.blank(UInt32(byte(at: position)))
        }
        return position
    }
}
