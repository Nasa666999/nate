import Foundation
import NateCore

struct CMakeScanner {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let rules: CMakeRules
    var budget: ANSILexingBudget
    var state: CMakeLexicalState
    var cursor = 0
    var emitted = 0
    var physicalStart = 0
    var styles: [UInt8]

    /// 业务作用：CMake 按原生逐字节顺序处理名称、注释和引号内变量，保留两个独立变量通道。
    /// 参数说明: 无。
    /// 返回：完整原字节类别与后继状态；范围、规则或预算不足时拒绝整批结果。
    mutating func scan() throws -> ([UInt8], CMakeLexicalState) {
        for index in bytes.indices {
            try budget.consume()
            cursor = index
            let current = bytes[index], following = try byte(at: index + 1)
            switch state.mode {
            case 0:
                if current == 35 {
                    try colour(until: index - 1, style: 0)
                    state.mode = 1
                }
                else if [34, 39, 96].contains(current) {
                    try colour(until: index - 1, style: 0)
                    beginString(current)
                }
                else if current == 36 || Self.name(current) {
                    try colour(until: index - 1, style: 0)
                    state.mode = 7
                    if Self.digit(current), [9, 32, 13, 10].contains(following) {
                        try colour(until: index, style: 14)
                    }
                }
            case 1:
                if current == 10 || current == 13 {
                    if try byte(at: index - 1) == 92 {
                        try colour(until: index - 2, style: 1)
                        try colour(until: index - 1, style: 0)
                    }
                    else {
                        try colour(until: index - 1, style: 1)
                        state.mode = 0
                    }
                }
            case 2, 3, 4:
                try string(current: current, following: following)
            case 7:
                try variable(current: current, following: following)
            default:
                throw NateError.message("CMake 连续状态缺少完整原生类别。")
            }
            if [2, 3, 4].contains(state.mode) {
                try stringVariables(current: current, following: following)
            }
            if current == 10 || current == 13 && following != 10 {
                physicalStart = index + 1
            }
        }
        try colour(until: bytes.count - 1, style: state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：CMake 单、双及反引号通道各自记录实际定界符，旧变量资格不能继承到新字面。
    /// 参数说明:
    /// - quote: 当前实际输入的原字节引号。
    /// 返回：对应引号类别开启，两个引号内变量通道复位。
    mutating func beginString(_ quote: UInt8) {
        state.mode = quote == 34 ? 2 : (quote == 96 ? 3 : 4)
        state.variableInString = false
        state.classicInString = false
    }

    /// 业务作用：未引用名称按原生终止、变量括号及转义条件收束，当前字符不被重复解释。
    /// 参数说明:
    /// - current: 当前原字节。
    /// - following: 同源下一原字节或真实 EOF 哨兵。
    /// 返回：已确认名称进入完整类别，后续引号及注释取得自己的通道。
    mutating func variable(current: UInt8, following: UInt8) throws {
        if current == 36 || current == 92 && [110, 114, 116].contains(following) {
            state.mode = 0
        }
        else if Self.name(current) && !Self.name(following) && following != 125 || current == 125 {
            state.mode = try classify(until: cursor)
            try colour(until: cursor, style: state.mode)
            state.mode = 0
        }
        else if !Self.name(current), current != 123, current != 125 {
            if try classify(until: cursor - 1) == 14 {
                try colour(until: cursor - 1, style: 14)
            }
            state.mode = 0
            if [34, 39, 96].contains(current) {
                beginString(current)
            }
            else if current == 35 {
                state.mode = 1
            }
        }
    }
}
