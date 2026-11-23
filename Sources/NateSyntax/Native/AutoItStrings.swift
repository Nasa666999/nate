import Foundation
import NateCore

extension AutoItScanner {
    /// 业务作用：双引号、单引号与 include 尖括号沿各自原生闭合符收束，续行保留原生字符串指示器的行尾重置顺序。
    /// 参数说明: 无。
    /// 返回：当前完整标量已按字面、SendKeys 或默认通道解释，闭合后的当前字符可由外层重新分派。
    mutating func string() throws {
        let value = try current()
        if state.string == 1 && value == 34 || state.string == 2 && value == 39
            || state.string == 3 && value == 62
        {
            try forward()
            try setState(0)
            state.string = 0
            return
        }
        if try atLineEnd() {
            state.string = 0
            if try !continuation() {
                try setState(0)
                return
            }
        }
        if [123, 43, 33, 94, 35].contains(value) {
            try setState(10)
        }
    }

    /// 业务作用：SendKeys 只解析有限原生候选，重复次数和方向开关不授予任意字符串键名资格。
    /// 参数说明:
    /// - word: 已完成 ASCII 小写及 CString 收束的候选。
    /// 返回：首段键名与次数或方向有效性；全部读取计入共同预算。
    mutating func sendKey(_ word: Data) throws -> (valid: Bool, key: Data) {
        var key = Data(), special = Data()
        var started = false, flag = false, numeric = true
        for value in word {
            try budget.consume()
            if value == 123 {
                started = true
            }
            if !started {
                continue
            }
            if value == 32 && !flag {
                flag = true
                key.append(125)
            }
            else if value == 32 {
                continue
            }
            else if !flag {
                key.append(value)
            }
            else if value != 125 {
                special.append(value)
                if !AutoItCharacters.digit(UInt32(value)) {
                    numeric = false
                }
            }
        }
        let known = ["down", "up", "on", "off", "toggle"].contains {
            special == Data($0.utf8)
        }
        return (numeric || known, key)
    }

    /// 业务作用：完整 SendKeys 先确认方向及键名再发布独立类别，未完成或无效候选整体回到字符串类别。
    /// 参数说明:
    /// - word: 当前明确以右花括号结束的有限候选。
    /// 返回：候选完整取得 SendKeys 或字符串类别，当前标量进入字符串通道；预算不足时抛错。
    mutating func finishSend(_ word: Data) throws {
        let (valid, key) = try sendKey(word)
        var known = false
        if valid {
            known = key.count == 3
            if !known {
                known = try rules.contains(key, group: 3, budget: &budget)
            }
        }
        state.mode = known ? 10 : 7
        try setState(7)
    }

    /// 业务作用：修饰键和花括号通道保留原生验证顺序，相邻键序列不吞并当前字符串闭合符。
    /// 参数说明:
    /// - word: 当前段在当前标量之前的有限原生候选。
    /// 返回：当前键序列或完整字面类别已确认；行尾不传播未完成 SendKeys，预算不足时抛错。
    mutating func sent(_ word: Data) throws {
        let value = try current()
        if previous == 125 && value != 125 {
            try finishSend(word)
        }
        else {
            var prefix = 1
            for byte in word {
                try budget.consume()
                if byte == 123 && prefix == 1 {
                    prefix = 2
                }
                if prefix == 1 && ![43, 33, 94, 35].contains(byte) {
                    prefix = 0
                }
                if prefix == 2 {
                    break
                }
            }
            if prefix == 0 || prefix == 1 && ![123, 43, 33, 94, 35].contains(value) {
                state.mode = 7
                try setState(7)
            }
        }
        if try atLineEnd() {
            state.mode = 7
            try setState(0)
            state.string = 0
        }
        if state.mode == 7 && [123, 43, 33, 94, 35].contains(value) {
            try setState(10)
        }
        if state.string == 1 && value == 34 || state.string == 2 && value == 39 {
            state.mode = 7
            try forward()
            try setState(0)
        }
    }
}
