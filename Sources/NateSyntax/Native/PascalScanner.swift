import Foundation
import NateCore

struct PascalScanner {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let rules: PascalRules
    let documentEnd: Bool
    var budget: ANSILexingBudget
    var state: PascalLexicalState
    var cursor = 0
    var emitted = 0
    var styles: [UInt8]

    /// 业务作用：Pascal 按原生状态与收束顺序分类完整物理行，真实 EOF 额外收束未闭合字面和关键字。
    /// 参数说明: 无。
    /// 返回：完整逐字节类别和后继状态；缺少原文证据、未知状态或超量时整份拒绝。
    mutating func scan() throws -> ([UInt8], PascalLexicalState) {
        let limit = bytes.count + (documentEnd ? 1 : 0)
        while cursor < limit {
            try budget.consume()
            if try atLineStart() {
                state.inStringIndent = true
            }
            let current = try byte(at: cursor)
            let following = try byte(at: cursor + 1)
            switch state.mode {
            case 0:
                break
            case 7:
                if !PascalCharacters.digit(current),
                    ![46, 45, 43, 101, 69].contains(current)
                        || current == 46 && following == 46
                {
                    try setState(0)
                }
                else if current == 45 || current == 43 {
                    let previous = try byte(at: cursor - 1)
                    if previous != 101 && previous != 69 {
                        try setState(0)
                    }
                }
            case 1:
                if !PascalCharacters.word(current) {
                    try classifyWord()
                }
            case 8:
                if !PascalCharacters.hex(current) {
                    try setState(0)
                }
            case 2, 5:
                if current == 125 {
                    cursor += 1
                    try setState(0)
                }
            case 3, 6:
                if current == 42, following == 41 {
                    cursor += 2
                    try setState(0)
                }
            case 4, 11:
                if try atLineStart() {
                    try setState(0)
                }
            case 10:
                if try atLineEnd() {
                    state.mode = 11
                }
                else if current == 39, following == 39 {
                    cursor += 1
                }
                else if current == 39 {
                    cursor += 1
                    try setState(0)
                }
            case 15:
                if state.inStringIndent {
                    state.inStringIndent = current == 9 || current == 32
                    if current == 39, following == 39, try byte(at: cursor + 2) == 39 {
                        let found = try quoteCount()
                        if found >= state.multilineQuotes {
                            cursor += state.multilineQuotes
                            try setState(0)
                        }
                    }
                }
            case 12:
                if !PascalCharacters.hex(current), current != 36 {
                    try setState(0)
                }
            case 13:
                if try byte(at: cursor - 1) == 59 {
                    state.inProperty = false
                    state.inExports = false
                }
                try setState(0)
            case 14:
                try setState(0)
            default:
                throw NateError.message("Pascal 连续状态缺少完整原生类别。")
            }
            if state.mode == 0 {
                try beginState()
            }
            cursor += 1
        }
        if state.mode == 1, try PascalCharacters.word(byte(at: cursor - 1)) {
            try classifyWord()
        }
        try colour(until: bytes.count - 1, style: state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：Pascal 普通代码进入数字、注释、指令、字面或汇编通道，进入顺序保留原生优先级。
    /// 参数说明: 无。
    /// 返回：当前原字节取得对应完整状态，真实 EOF 不建立额外正文字符。
    mutating func beginState() throws {
        let current = try byte(at: cursor), following = try byte(at: cursor + 1)
        if PascalCharacters.digit(current), !state.inAssembler {
            try setState(7)
        }
        else if PascalCharacters.wordStart(current) {
            try setState(1)
        }
        else if current == 36, !state.inAssembler {
            try setState(8)
        }
        else if current == 123 {
            try setState(following == 36 ? 5 : 2)
        }
        else if current == 40, following == 42 {
            let directive = try byte(at: cursor + 2) == 36
            try setState(directive ? 6 : 3)
            if !directive {
                cursor += 1
            }
        }
        else if current == 47, following == 47 {
            try setState(4)
        }
        else if current == 39 {
            let count = try quoteCount()
            let after = try byte(at: cursor + count)
            if count >= 3, count % 2 == 1, after == 13 || after == 10 {
                state.multilineQuotes = count
                try setState(15)
                cursor += count
            }
            else {
                try setState(10)
            }
        }
        else if current == 35 {
            try setState(12)
        }
        else if PascalCharacters.operation(current), !state.inAssembler {
            try setState(13)
        }
        else if state.inAssembler {
            try setState(14)
        }
    }
}
