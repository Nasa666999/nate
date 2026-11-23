import Foundation
import NateCore

extension ASMScanner {
    /// 业务作用：汇编按原生次序开启注释、数值、名称、三类引号和操作符，前瞻不执行指令。
    /// 参数说明: 无。
    /// 返回：当前真实原字节取得对应状态，名称只有完整同源后继确认后才能使用词表类别。
    mutating func beginState() throws {
        let current = try byte(at: cursor), following = try byte(at: cursor + 1)
        if current == 59 {
            try setState(1)
        }
        else if ASMCharacters.digit(current) || current == 46 && ASMCharacters.digit(following) {
            try setState(2)
        }
        else if ASMCharacters.wordStart(current) {
            let word = try wordClass(start: base + cursor)
            state.wordStyle = word.style
            state.directiveComment = word.comment
            try setState(5)
        }
        else if current == 34 {
            try setState(3)
        }
        else if current == 39 {
            try setState(12)
        }
        else if current == 96 {
            try setState(16)
        }
        else if ASMCharacters.operation(current) {
            try setState(4)
        }
    }

    /// 业务作用：名称跨反斜杠物理续行时先确认完整类别，未显示的后继不能留下此前行的临时身份。
    /// 参数说明:
    /// - start: 当前名称在固定原文中的真实起点。
    /// 返回：六组有序词表授予的类别及 COMMENT 指令资格；一 MiB 前瞻或共同预算不足时拒绝。
    mutating func wordClass(start: Int) throws -> (style: UInt8, comment: Bool) {
        var position = start
        var candidate: [UInt8] = []
        while true {
            try budget.consume()
            guard position >= start, position - start <= 1_048_576 else {
                throw NateError.message("汇编名称前瞻超过 1 MiB 的完整证据预算。")
            }
            let value = try sourceByte(at: position)
            if position > start, value == 92 {
                let next = try sourceByte(at: position + 1)
                if next == 13 || next == 10 {
                    var width = 2
                    if next == 13, try sourceByte(at: position + 2) == 10 {
                        width = 3
                    }
                    for offset in 0..<width where candidate.count < 99 {
                        candidate.append(ASMCharacters.folded(try sourceByte(at: position + offset)))
                    }
                    position += width
                    continue
                }
            }
            if position > start, !ASMCharacters.word(value) {
                break
            }
            if candidate.count < 99 {
                candidate.append(ASMCharacters.folded(value))
            }
            position += 1
        }
        let word = Data(candidate)
        for (group, style) in [UInt8(6), 7, 8, 9, 10, 14].enumerated() {
            if try rules.contains(word, group: group, budget: &budget) {
                return (style, style == 9 && word == Data("comment".utf8))
            }
        }
        return (5, false)
    }

    /// 业务作用：前瞻只读取本轮固定全文或完整独立正文，真实边缘不引入其它来源的名称字符。
    /// 参数说明:
    /// - position: 固定正文中的绝对原字节坐标。
    /// 返回：实际原字节或 NUL 哨兵；共同预算不足时拒绝。
    mutating func sourceByte(at position: Int) throws -> UInt8 {
        try budget.consume()
        if let snapshot {
            return snapshot.text.byte(at: position) ?? 0
        }
        let local = position - base
        return local >= 0 && local < bytes.count ? bytes[local] : 0
    }
}
