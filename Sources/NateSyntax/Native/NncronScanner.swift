import Foundation
import NateCore

struct NncronScanner {
    let bytes: [UInt8]
    let rules: NncronRules
    var budget: ANSILexingBudget
    var state: NncronLexicalState
    var cursor = 0
    var emitted = 0
    var wordStart = 0
    var styles: [UInt8]

    /// 业务作用：nnCron 依原生逐字节状态顺序分类完整范围，未被收束的 EOF 名称不猜测关键字身份。
    /// 参数说明: 无。
    /// 返回：完整原字节样式及后继状态；步骤或截止不足时拒绝整份结果。
    mutating func scan() throws -> ([UInt8], NncronLexicalState) {
        while cursor < bytes.count {
            try budget.consume()
            let current = byte(cursor)
            switch state.mode {
            case 0:
                try beginState(current)
            case 1, 2:
                if current == 10 || current == 13 {
                    state.mode = 0
                }
                else {
                    try colour(until: cursor, style: state.mode)
                }
            case 8:
                if current == 37 {
                    state.mode = 9
                    state.insideString = true
                    try colour(until: cursor - 1, style: 8)
                }
                else {
                    if current == 34 && byte(cursor - 1) != 92 || current == 10 || current == 13 {
                        state.mode = 0
                    }
                    try colour(until: cursor, style: 8)
                }
            case 9:
                if current == 37 && state.insideString {
                    state.mode = 8
                    state.insideString = false
                }
                else if current == 37 && byte(cursor - 1) != 92 || current == 10 || current == 13
                    || current == 62
                {
                    state.mode = 0
                    try colour(until: cursor, style: 9)
                }
                else {
                    try colour(until: cursor + 1, style: 9)
                }
            case 10:
                if !NncronCharacters.word(current) {
                    let word = Data(bytes[wordStart..<cursor])
                    state.mode = 0
                    if try rules.contains(word, group: 0, budget: &budget) {
                        try colour(until: cursor, style: 3)
                    }
                    else if try rules.contains(word, group: 1, budget: &budget) {
                        try colour(until: cursor - 1, style: 4)
                    }
                    else if try rules.contains(word, group: 2, budget: &budget) {
                        try colour(until: cursor - 1, style: 5)
                    }
                    else {
                        try colour(until: cursor - 1, style: 0)
                    }
                    cursor -= 1
                }
            case 7:
                if !NncronCharacters.digit(current) {
                    state.mode = 0
                    try colour(until: cursor - 1, style: 7)
                    cursor -= 1
                }
            default:
                throw NateError.message("nnCron 连续状态缺少完整原生类别。")
            }
            cursor += 1
        }
        try budget.check()
        return (styles, state)
    }
}
