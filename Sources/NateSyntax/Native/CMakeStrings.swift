import Foundation

extension CMakeScanner {
    /// 业务作用：原生引号按美元反斜杠组合、同类闭合符及真实物理行尾顺序收束。
    /// 参数说明:
    /// - current: 当前原字节。
    /// - following: 同源下一原字节或真实 EOF 哨兵。
    /// 返回：闭合或非续行时完成当前字面，合格续行保留原通道。
    mutating func string(current: UInt8, following: UInt8) throws {
        if try byte(at: cursor - 1) == 92, try byte(at: cursor - 2) == 36 {
            return
        }
        let quote: UInt8 = state.mode == 2 ? 34 : (state.mode == 3 ? 96 : 39)
        if current == quote {
            try colour(until: cursor, style: state.mode)
            state.mode = 0
            return
        }
        if following == 13 || following == 10 {
            var back = cursor, continues = false
            // 后继结束符已进入下一物理行时，不能跨回上一行寻找续行反斜杠。
            if current != 10 && !(current == 13 && following != 10) {
                while back >= physicalStart && base + back > 0 {
                    try budget.consume()
                    let value = bytes[back]
                    if value == 92 {
                        continues = true
                        break
                    }
                    if ![13, 10, 9, 32].contains(value) {
                        break
                    }
                    back -= 1
                }
            }
            if continues {
                try colour(until: cursor + 1, style: state.mode)
            }
            else {
                try colour(until: cursor, style: state.mode)
                state.mode = 0
            }
        }
    }

    /// 业务作用：引号内普通美元名称与花括号变量分别传播，提前封闭的后继字符不重复着色。
    /// 参数说明:
    /// - current: 当前原字节。
    /// - following: 同源下一原字节或真实 EOF 哨兵。
    /// 返回：完整变量范围采用专用类别，当前引号及未完成通道按原生顺序继续。
    mutating func stringVariables(current: UInt8, following: UInt8) throws {
        var ignoreDollar = false
        if state.variableInString, current == 36 {
            state.variableInString = false
            ignoreDollar = true
        }
        else if state.variableInString, current == 92, [110, 114, 116, 34, 96, 39].contains(following) {
            try colour(until: cursor + 1, style: 13)
            state.variableInString = false
        }
        else if state.variableInString, !Self.name(following) {
            if try classify(until: cursor) == 7 {
                try colour(until: cursor, style: 13)
            }
            state.variableInString = false
        }
        else if state.classicInString, following == 125 {
            try colour(until: cursor + 1, style: 13)
            state.classicInString = false
        }
        if !ignoreDollar, current == 36, following == 123 {
            try colour(until: cursor - 1, style: state.mode)
            state.classicInString = true
            state.variableInString = false
        }
        else if !ignoreDollar, current == 36 {
            try colour(until: cursor - 1, style: state.mode)
            state.variableInString = true
            state.classicInString = false
        }
    }
}
