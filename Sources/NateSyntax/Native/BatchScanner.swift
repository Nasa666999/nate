import Foundation
import NateCore

struct BatchScanner {
    let bytes: [UInt8]
    let base: Int
    let rules: BatchRules
    var budget: ANSILexingBudget
    var state: BatchLexicalState
    var offset = 0
    var command = 0
    var wordStart = 0
    var wordEnd = 0
    var painted = 0
    var styles: [UInt8]

    /// 业务作用：Batch 按完整物理行与原生命令顺序分类，保留关闭关键字检查后的续行状态。
    /// 参数说明:
    /// - hasFollowing: 当前物理范围之后仍有实际原文。
    /// 返回：完整原字节类别及后继状态；容量、取消或截止不足时不交付部分结果。
    mutating func scan(hasFollowing: Bool) throws -> ([UInt8], BatchLexicalState) {
        offset = try skippedSpace(offset)
        try colour(until: offset - 1, style: 0)
        command = offset
        let stopped = try initialLine()
        if byte(offset) == 64 {
            try colour(until: offset, style: 4)
            offset += 1
        }
        offset = try skippedSpace(offset)
        while offset < bytes.count && !stopped {
            try budget.consume()
            if offset > base {
                try colour(until: offset - 1, style: 0)
            }
            wordStart = offset
            offset = try skippedNonSpace(offset)
            wordEnd = offset
            let first = word(0)
            if state.processing, try equals("rem") || starts("::") {
                if try offset == wordEnd - wordStart || !quoted(until: wordStart) {
                    try colour(until: wordStart - 1, style: 0)
                    try colour(until: bytes.count - 1, style: 1)
                    break
                }
            }
            if Self.separator(first) {
                var style: UInt8 = 0
                offset = wordStart + 1
                if command == wordStart, [58, 92, 46].contains(first) {
                    if try externalAllowed() {
                        style = 5
                    }
                    command = offset
                }
                try colour(until: offset - 1, style: style)
            }
            else if state.processing, try listed(group: 0) {
                try keyword()
            }
            else if state.processing, !Self.op(first), first != 37, first != 33 {
                try ordinaryCommand()
            }
            else if first == 37 {
                try percentVariable()
            }
            else if first == 33 {
                try delayedVariable()
            }
            else if Self.op(first) {
                try operatorWord()
            }
            else {
                let count = try wordLength()
                try colour(until: wordStart + count - 1, style: 0)
                offset = wordStart + count
            }
            offset = try skippedSpace(offset)
        }
        try colour(until: bytes.count - 1, style: 0)
        if !state.processing, hasFollowing {
            state.processing = !(try continuation())
        }
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：Batch 行首独立识别完整标签、双冒号注释和盘符切换，不把后继内容重解释为命令。
    /// 参数说明: 无。
    /// 返回：当前整行已由标签、注释或盘符接管时为真。
    mutating func initialLine() throws -> Bool {
        if byte(offset) == 58 {
            if byte(offset + 1) == 58 {
                try colour(until: bytes.count - 1, style: 1)
            }
            else {
                var end = offset + 1
                while end < bytes.count && [9, 32].contains(byte(end)) {
                    try budget.consume()
                    end += 1
                }
                if end == bytes.count {
                    end = 0
                }
                while end < bytes.count && ![9, 32, 38, 43, 58, 60, 62, 124].contains(byte(end)) {
                    try budget.consume()
                    end += 1
                }
                if end < bytes.count {
                    try colour(until: end - 1, style: 3)
                    try colour(until: bytes.count - 1, style: 8)
                }
                else {
                    try colour(until: bytes.count - 1, style: 3)
                }
            }
            return true
        }
        if Self.alpha(byte(offset)), byte(offset + 1) == 58,
            Self.space(byte(offset + 2)) || byte(offset + 2) == 92 && Self.space(byte(offset + 3))
        {
            try colour(until: bytes.count - 1, style: 2)
            return true
        }
        return false
    }
}
