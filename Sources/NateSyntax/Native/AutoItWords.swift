import Foundation
import NateCore

extension AutoItScanner {
    /// 业务作用：块注释只接受当前行首个有效候选的结束指令，分号之后不能解除块注释。
    /// 参数说明:
    /// - word: 当前原生九十九字节候选。
    /// 返回：原生块注释、行内尾注释或默认通道已确认；预算不足时抛错。
    mutating func blockComment(_ word: Data) throws {
        let closing = word == Data("#ce".utf8) || word == Data("#comments-end".utf8)
        if try atLineEnd() {
            state.comment = 0
            if closing {
                try setState(0)
            }
            return
        }
        if previous == 59 {
            state.comment = 2
            try setState(2)
        }
        if state.comment == 2 {
            return
        }
        let value = try current()
        if state.comment == 0 {
            if AutoItCharacters.wordStart(value & 255) || AutoItCharacters.operation(value) {
                state.comment = 1
                try setState(2)
            }
            return
        }
        if !(AutoItCharacters.word(value) || value == 45 && word == Data("#comments".utf8)) {
            if closing {
                try setState(1)
            }
            else {
                state.comment = 2
            }
        }
    }

    /// 业务作用：名称结束后按原生优先级回填类别，include 和区域指令各自继续其余当前行语义。
    /// 参数说明:
    /// - word: 由同一当前段取得的原生小写候选。
    /// 返回：名称类别及 include 字面资格已经确认；预算不足时抛错。
    mutating func keyword(_ word: Data) throws {
        let value = try current()
        let joined = value == 45 && [Data("#comments".utf8), Data("#include".utf8)].contains(word)
        if !AutoItCharacters.word(value) && !joined && value != 36 {
            let mode = try classify(word)
            state.mode = mode
            try setState(mode == 2 || mode == 12 ? mode : 0)
            if mode == 2 {
                return
            }
            if mode == 11 && word == Data("#include".utf8) {
                state.string = 3
            }
        }
        if try atLineEnd() {
            try setState(0)
        }
    }

    /// 业务作用：数字独立保存十六进制、指数及点状态，重复点使完整待定数值按原生默认类别收束。
    /// 参数说明:
    /// - word: 同一数字段的原生有限候选。
    /// 返回：数值状态或其完整类别已经更新；预算不足时抛错。
    mutating func number(_ word: Data) throws {
        let value = try current()
        if word == Data([48]) && [88, 120].contains(value) && state.number == 0 {
            state.number = 2
            return
        }
        if AutoItCharacters.digit(previous) && [69, 101].contains(value) && state.number <= 1 {
            state.number = 3
            return
        }
        if state.number == 2 && ((65...70).contains(value) || (97...102).contains(value)) {
            return
        }
        if value == 46 {
            state.number = state.number == 0 ? 1 : 9
            return
        }
        if !AutoItCharacters.digit(value) {
            if state.number == 9 {
                state.mode = 0
            }
            try setState(0)
        }
    }
}
