import Foundation
import NateCore

struct AdaScanner {
    var bytes: [UInt8]
    var base = 0
    var snapshot: DocumentSnapshot?
    var documentEnd = true
    let rules: AdaRules
    var budget: ANSILexingBudget
    var state: AdaLexicalState
    var cursor = 0
    var emitted = 0
    var currentLine = 0
    var previous: UInt32 = 0
    var eofSpace = false
    var starts: [Int] = [0]
    var styles: [UInt8]

    /// 业务作用：Ada 按原生分支顺序解释完整标量，属性撇号资格跨物理行保留，类别不跨行无条件延续。
    /// 参数说明: 无。
    /// 返回：完整原字节类别及后继状态；任一读取、规则或共同预算不足时整份抛错。
    mutating func scan() throws -> ([UInt8], AdaLexicalState) {
        for index in bytes.indices {
            try budget.consume()
            if bytes[index] == 10
                || bytes[index] == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)
            {
                starts.append(index + 1)
            }
        }
        while more() {
            try budget.consume()
            if atLineEnd() {
                try forward(allowFollowingLine: false)
                try setState(0)
                if cursor == bytes.count && !documentEnd {
                    break
                }
            }
            let value = try current()
            if try value == 45 && next() == 45 {
                try setState(10)
                while !atLineEnd() {
                    try forward()
                }
            }
            else if value == 34 {
                state.apostropheStartsAttribute = true
                try setState(7)
                try forward()
                try context(closing: 34, error: 8)
            }
            else if value == 39 && !state.apostropheStartsAttribute {
                state.apostropheStartsAttribute = true
                try setState(5)
                try forward()
                try forward()
                try context(closing: 39, error: 6)
            }
            else if try value == 60 && next() == 60 {
                try label()
            }
            else if AdaCharacters.space(value) {
                try setState(0)
                try forwardState(0)
            }
            else if AdaCharacters.delimiter(value) {
                state.apostropheStartsAttribute = value == 41
                try setState(4)
                try forwardState(0)
            }
            else if (48...57).contains(value) || value == 35 {
                try number()
            }
            else {
                try word()
            }
        }
        try setState(state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：字符和字符串仅在原生物理行尾或实际闭合符收束，不把 EOF 扩成额外正文。
    /// 参数说明:
    /// - closing: 当前通道真实闭合标量。
    /// - error: 物理行尾尚未闭合时的完整原生类别。
    /// 返回：字面完整闭合或取得原生行尾类别；失去预算时抛错。
    mutating func context(closing: UInt32, error: UInt8) throws {
        while try !atLineEnd() && current() != closing {
            try forward()
        }
        if !atLineEnd() {
            try forwardState(0)
        }
        else {
            state.mode = error
        }
    }

    /// 业务作用：完整名称按原生 char 转换后验证，只有合法名称才查询原词表，all 保留属性撇号资格。
    /// 参数说明: 无。
    /// 返回：名称取得标识符、关键字或非法类别，后继属性资格同步更新；失败不发布局部结果。
    mutating func word() throws {
        state.apostropheStartsAttribute = true
        try setState(2)
        var raw: [UInt8] = []
        while try !atLineEnd() && !AdaCharacters.separator(current()) {
            raw.append(AdaCharacters.folded(try current()))
            try forward()
        }
        if try !AdaCharacters.identifier(raw, budget: &budget) {
            state.mode = 11
        }
        else if try rules.contains(Data(raw), group: 0, budget: &budget) {
            state.mode = 1
            if raw != Array("all".utf8) {
                state.apostropheStartsAttribute = false
            }
        }
        try setState(0)
    }

    /// 业务作用：标签必须含合法且非关键字的完整名称和实际双右括号，标签后的撇号开始字符通道。
    /// 参数说明: 无。
    /// 返回：完整标签或非法范围已经收束；任何预算失败拒绝整份类别。
    mutating func label() throws {
        state.apostropheStartsAttribute = false
        try setState(9)
        try forward()
        try forward()
        var raw: [UInt8] = []
        while try !atLineEnd() && !AdaCharacters.separator(current()) {
            raw.append(AdaCharacters.folded(try current()))
            try forward()
        }
        if try current() == 62 && next() == 62 {
            try forward()
            try forward()
        }
        else {
            state.mode = 11
        }
        if try !AdaCharacters.identifier(raw, budget: &budget)
            || rules.contains(Data(raw), group: 0, budget: &budget)
        {
            state.mode = 11
        }
        try setState(0)
    }

    /// 业务作用：数值保留点范围分隔及带符号指数的原生收集顺序，完整验证后统一发布数值或非法范围。
    /// 参数说明: 无。
    /// 返回：数值类别及后继属性资格完整收束；超量或取消时抛错。
    mutating func number() throws {
        state.apostropheStartsAttribute = true
        try setState(3)
        var raw: [UInt8] = []
        while true {
            let value = try current()
            guard try !AdaCharacters.separator(value) || value == 46 && next() != 46 else {
                break
            }
            raw.append(UInt8(truncatingIfNeeded: value))
            try forward()
        }
        if [69, 101].contains(previous), [43, 45].contains(try current()) {
            raw.append(UInt8(truncatingIfNeeded: try current()))
            try forward()
            while !AdaCharacters.separator(try current()) {
                raw.append(UInt8(truncatingIfNeeded: try current()))
                try forward()
            }
        }
        if try !AdaNumbers.valid(raw, budget: &budget) {
            state.mode = 11
        }
        try setState(0)
    }
}
