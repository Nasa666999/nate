import Foundation
import NateCore

struct ASMFoldScanner {
    let bytes: [UInt8]
    let styles: [UInt8]
    let starts: [Int]
    let rules: ASMRules
    var budget: ANSILexingBudget

    /// 业务作用：汇编折叠使用同源完整类别、八组词表中的开闭声明及原生注释标记，保留当前和后继行层级。
    /// 参数说明: 无。
    /// 返回：完整原生打包层级与标志；层级、来源或共同预算不足时拒绝整份结果。
    mutating func levels() throws -> [Int] {
        guard bytes.count == styles.count, starts.first == 0 else {
            throw NateError.invalidRange
        }
        var output = Array(repeating: 1024, count: starts.count)
        var current = 1024, next = 1024, line = 0
        var previousStyle: UInt8 = 0
        var word: [UInt8] = []
        for index in bytes.indices {
            try budget.consume()
            let value = bytes[index]
            let following: UInt8 = index + 1 < bytes.count ? bytes[index + 1] : 32
            let style = styles[index]
            let followingStyle: UInt8 = index + 1 < styles.count ? styles[index + 1] : 0
            let end = value == 13 && following != 10 || value == 10
            if style == 15 || style == 11 {
                if previousStyle != 15 && previousStyle != 11 {
                    next += 1
                }
                else if followingStyle != 15 && followingStyle != 11 && !end {
                    next -= 1
                }
            }
            if style == 1, value == 59 {
                if following == 123 {
                    next += 1
                }
                else if following == 125 {
                    next -= 1
                }
            }
            if style == 9 {
                word.append(ASMCharacters.folded(value))
                if followingStyle != 9 {
                    let candidate = Data(word)
                    if try rules.contains(candidate, group: 6, budget: &budget) {
                        next += 1
                    }
                    else if try rules.contains(candidate, group: 7, budget: &budget) {
                        next -= 1
                    }
                    word.removeAll(keepingCapacity: true)
                }
            }
            // 原生层级字段只能完整表示有限范围，越界后不能把高位误当折叠标志隐藏正文。
            guard (0...4095).contains(current), (0...4095).contains(next) else {
                throw NateError.message("汇编折叠层级超过完整表示范围。")
            }
            if end || index == bytes.count - 1 {
                guard line < output.count else {
                    throw NateError.invalidRange
                }
                output[line] = current | next << 16 | (current < next ? 8192 : 0)
                line += 1
                current = next
                if end, index == bytes.count - 1 {
                    guard line < output.count else {
                        throw NateError.invalidRange
                    }
                    output[line] = current | current << 16 | 4096
                }
            }
            previousStyle = style
        }
        try budget.check()
        return output
    }
}
