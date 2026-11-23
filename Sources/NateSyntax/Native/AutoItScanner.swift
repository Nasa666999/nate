import Foundation
import NateCore

struct AutoItScanner {
    let bytes: [UInt8]
    var documentEnd = true
    let rules: AutoItRules
    var budget: ANSILexingBudget
    var state: AutoItLexicalState
    var cursor = 0
    var emitted = 0
    var previous: UInt32 = 0
    var styles: [UInt8]
    var lineStarts = [0]
    var candidateBase = -1
    var candidateRawCount = 0
    var candidateTerminated = false
    var candidateValue = Data()
    var saved: (start: Int, end: Int, character: UInt8)?

    /// 业务作用：AutoIt 按原生通道与消费顺序分类，续行字符串和块注释只传播明确的语言状态。
    /// 参数说明: 无。
    /// 返回：完整原字节类别及后继状态；范围、资源或共同预算不足时整份抛错。
    mutating func scan() throws -> ([UInt8], AutoItLexicalState) {
        try prepareLines()
        while more() {
            try budget.consume()
            let value = try current()
            let word = try candidate()
            if AutoItCharacters.word(value) || value == 125 {
                saved = (emitted, cursor, AutoItCharacters.lower(UInt8(value)))
            }
            switch state.mode {
            case 0:
                break
            case 1:
                if try atLineEnd() {
                    try setState(0)
                }
            case 2:
                try blockComment(word)
            case 3:
                try number(word)
            case 5:
                try keyword(word)
            case 7:
                try string()
            case 8:
                try setState(previous == 46 && AutoItCharacters.word(value) ? 14 : 0)
            case 9:
                if try value == 46 && !AutoItCharacters.digit(next()) {
                    try setState(8)
                }
                else if !AutoItCharacters.word(value) {
                    try setState(0)
                }
            case 10:
                try sent(word)
            case 12:
                if value == 59 {
                    try setState(1)
                }
                if try atLineEnd() {
                    try setState(0)
                }
            case 14:
                if !AutoItCharacters.word(value) {
                    try setState(0)
                }
            default:
                throw NateError.message("AutoIt 连续状态缺少有效原生通道。")
            }
            if state.mode == 0 {
                try begin()
            }
            try forward()
        }
        if documentEnd {
            if state.mode == 5 {
                let word = try savedCandidate()
                state.mode = try classify(word, final: true)
                try setState(state.mode)
            }
            if state.mode == 10 {
                if try previous == 125 && current() != 125 {
                    try finishSend(try savedCandidate())
                }
                if try atLineEnd() {
                    state.mode = 7
                    try setState(0)
                }
            }
        }
        try setState(state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：仅原生默认通道取得名称、变量、字面和数值的开端资格，已有闭合后的当前字符仍可重新分派。
    /// 参数说明: 无。
    /// 返回：当前完整标量已进入适用通道，其它输入继续默认；预算不足时抛错。
    mutating func begin() throws {
        let value = try current()
        if value == 59 {
            try setState(1)
        }
        else if value == 35 || value == 64 {
            try setState(5)
        }
        else if value == 36 {
            try setState(9)
        }
        else if try value == 46 && !AutoItCharacters.digit(next()) {
            try setState(8)
        }
        else if value == 60 && state.string == 3 {
            try setState(7)
        }
        else if value == 34 || value == 39 {
            try setState(7)
            state.string = value == 34 ? 1 : 2
        }
        else if try AutoItCharacters.digit(value) || value == 46 && AutoItCharacters.digit(next()) {
            try setState(3)
            state.number = 0
        }
        else if AutoItCharacters.wordStart(value) {
            try setState(5)
        }
        else if AutoItCharacters.operation(value) {
            try setState(8)
        }
        else if try atLineEnd() {
            try setState(0)
        }
    }
}
