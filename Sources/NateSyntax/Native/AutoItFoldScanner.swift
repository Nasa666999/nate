import Foundation
import NateCore

struct AutoItFoldScanner {
    let bytes: [UInt8]
    let styles: [UInt8]
    let starts: [Int]
    var budget: ANSILexingBudget

    /// 业务作用：完整原文、完整类别及真实物理行共同计算原生控制流、区域、预处理和注释层级，EOF 不伪造结束字符。
    /// 参数说明: 无。
    /// 返回：完整有限原生行层级；缺少范围、层级超限或预算不足时拒绝全部结果。
    mutating func levels() throws -> [Int] {
        guard bytes.count <= 67_108_864, styles.count == bytes.count,
            !starts.isEmpty, starts.count <= 1_048_576, starts.first == 0
        else {
            throw NateError.invalidRange
        }
        var output = Array(repeating: 1024, count: starts.count)
        var state = AutoItFoldState()
        var line = 0
        var style = try firstStyle(0), previousStyle: UInt8 = 0
        var previous: UInt8 = 32
        var firstStart = false, firstEnd = false, foundThen = false
        var keyword: [UInt8] = [], then: [UInt8] = []
        for index in bytes.indices {
            try budget.consume()
            let byte = bytes[index], value = UInt32(byte)
            if firstStart && !firstEnd {
                if !AutoItCharacters.word(value) {
                    firstEnd = true
                }
                else if keyword.count < 10 {
                    keyword.append(AutoItCharacters.lower(byte))
                }
            }
            if !firstStart
                && (AutoItCharacters.word(value) || AutoItCharacters.wordStart(value) || byte == 59)
            {
                firstStart = true
                keyword.append(AutoItCharacters.lower(byte))
            }
            if styles[index] != 1 {
                if foundThen && AutoItCharacters.word(value) {
                    foundThen = false
                }
                if firstEnd && keyword == [105, 102] {
                    if then.count == 4 {
                        then.removeFirst()
                        then.append(AutoItCharacters.lower(byte))
                        if then == [116, 104, 101, 110] {
                            foundThen = true
                        }
                    }
                    else {
                        then.append(AutoItCharacters.lower(byte))
                    }
                }
            }
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == 10 || byte == 13 && following != 10 {
                if !keyword.isEmpty && previous != 95 && ![1, 2].contains(style) {
                    state.keyword(keyword, then: foundThen)
                }
                let nextStyle = try firstStyle(line + 1)
                state.adjacent(before: previousStyle, current: style, after: nextStyle)
                // 原生层级低位同时承载显示标志，超出其有效位宽时不能发布可能隐藏错误正文的范围。
                guard output.indices.contains(line), (0...4095).contains(state.current),
                    (0...4095).contains(state.next)
                else {
                    throw NateError.message("AutoIt 折叠层级超出 0–4095。")
                }
                output[line] = state.current | state.next << 16 | (state.current < state.next ? 8192 : 0)
                line += 1
                previousStyle = style
                style = nextStyle
                state.current = state.next
                if previous != 95 {
                    keyword = []
                    then = []
                    firstStart = false
                    firstEnd = false
                    foundThen = false
                }
            }
            if ![9, 10, 11, 12, 13, 32].contains(byte) {
                previous = byte
            }
        }
        try budget.check()
        return output
    }

    /// 业务作用：行首类别采用原生跳过空白规则，空行与真实 EOF 保持各自的默认类别证据。
    /// 参数说明:
    /// - line: 当前固定正文中的物理行或紧邻 EOF 行。
    /// 返回：首个原生有效字节的类别，EOF 为默认；边界或预算不足时抛错。
    mutating func firstStyle(_ line: Int) throws -> UInt8 {
        guard line >= 0 else {
            throw NateError.invalidRange
        }
        var start = line < starts.count ? starts[line] : bytes.count
        let end = (line + 1 < starts.count ? starts[line + 1] : bytes.count) - 1
        guard start >= 0, start <= bytes.count, end < bytes.count else {
            throw NateError.invalidRange
        }
        while start < end, [9, 10, 11, 12, 13, 32].contains(bytes[start]) {
            try budget.consume()
            start += 1
        }
        return start < styles.count ? styles[start] : 0
    }
}
