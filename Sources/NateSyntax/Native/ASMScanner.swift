import Foundation
import NateCore

struct ASMScanner {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let rules: ASMRules
    let documentEnd: Bool
    var budget: ANSILexingBudget
    var state: ASMLexicalState
    var cursor = 0
    var emitted = 0
    var styles: [UInt8]

    /// 业务作用：汇编沿完整原文分类指令、字面和注释，通用反斜杠续行先于具体状态动作。
    /// 参数说明: 无。
    /// 返回：完整逐字节样式和后继状态，来源前瞻或共同预算不足时拒绝整份分类。
    mutating func scan() throws -> ([UInt8], ASMLexicalState) {
        if state.mode == 13 {
            state.mode = 0
        }
        let limit = bytes.count + (documentEnd ? 1 : 0)
        while cursor < limit {
            try budget.consume()
            if try atLineStart() {
                if [3, 12, 16].contains(state.mode) {
                    try setState(state.mode)
                }
                else if state.mode == 1 {
                    try setState(0)
                }
            }
            let current = try byte(at: cursor), following = try byte(at: cursor + 1)
            if current == 92, following == 10 || following == 13 {
                cursor += 1
                if try byte(at: cursor) == 13, try byte(at: cursor + 1) == 10 {
                    cursor += 1
                }
                cursor += 1
                continue
            }
            switch state.mode {
            case 0, 1:
                break
            case 4:
                if !ASMCharacters.operation(current) {
                    try setState(0)
                }
            case 2:
                if !ASMCharacters.word(current) {
                    try setState(0)
                }
            case 5:
                if !ASMCharacters.word(current) {
                    let directive = state.directiveComment
                    try setState(0)
                    if directive {
                        while try [9, 32].contains(byte(at: cursor)), try !atLineEnd() {
                            cursor += 1
                            try setState(0)
                        }
                        if try byte(at: cursor) == 126 {
                            try setState(15)
                        }
                    }
                }
            case 15:
                if current == 126 {
                    while cursor < bytes.count, try !matchLineEnd() {
                        try budget.consume()
                        cursor += 1
                    }
                    try setState(0)
                }
            case 3, 12, 16:
                let quote: UInt8 = state.mode == 3 ? 34 : (state.mode == 12 ? 39 : 96)
                if current == 92 {
                    if [34, 39, 92].contains(following) || state.mode == 16 && following == 96 {
                        cursor += 1
                    }
                }
                else if current == quote {
                    cursor += 1
                    try setState(0)
                }
                else if try atLineEnd() {
                    state.mode = 13
                    cursor += 1
                    try setState(0)
                }
            default:
                throw NateError.message("汇编连续状态缺少完整原生类别。")
            }
            if state.mode == 0, cursor < bytes.count {
                try beginState()
            }
            cursor += 1
        }
        try colour(until: bytes.count - 1, style: state.mode == 5 ? state.wordStyle : state.mode)
        try budget.check()
        return (styles, state)
    }
}
