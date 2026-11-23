import Foundation
import NateCore

struct FortranScanner {
    var bytes: [UInt8]
    let rules: FortranRules
    var budget: ANSILexingBudget
    var state: FortranLexicalState
    var styles: [UInt8]
    var snapshot: DocumentSnapshot? = nil
    var base = 0
    var documentEnd = true
    var cursor = 0
    var emitted = 0
    var starts = [0]
    var currentLine = 0
    var lineStart = 0
    var nonblank = 0
    var atLineStart = true

    /// 业务作用：固定原文中的格式列、续行、预处理及字面状态按原生动作顺序解释后才交付完整分类。
    /// 参数说明: 无。
    /// 返回：完整逐字节类别及结束状态；容量、取消或截止不足时拒绝部分结果。
    mutating func scan() throws -> ([UInt8], FortranLexicalState) {
        guard bytes.count <= 1_048_576, styles.count == bytes.count else {
            throw NateError.message("Fortran 原文上下文超过 1 MiB 或样式容量不一致。")
        }
        try budget.check()
        var index = 0
        while index < bytes.count {
            try budget.consume()
            if bytes[index] == 13 || bytes[index] == 10 {
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 1
                }
                starts.append(index + 1)
            }
            index += 1
        }
        while more() {
            try budget.consume()
            if atLineStart {
                lineStart = cursor
                nonblank = 0
                try setState(0)
            }
            let value = try current()
            if value != 32, value != 9 {
                nonblank += 1
            }
            if try fixedPrefix() {
                try forward(allowFollowingLine: false)
                continue
            }
            try continuation()
            if try current() == 35, nonblank == 1 {
                try setState(11)
                while !atLineEnd(), more() {
                    try forward()
                }
            }
            try finishToken()
            if state.mode == 0 {
                try enterToken()
            }
            try forward(allowFollowingLine: false)
        }
        try setState(state.mode)
        try budget.check()
        return (styles, state)
    }
}
