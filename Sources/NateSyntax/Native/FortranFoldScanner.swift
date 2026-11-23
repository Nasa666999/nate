import Foundation
import NateCore

struct FortranFoldScanner {
    let bytes: [UInt8]
    let styles: [UInt8]
    let starts: [Int]
    let fixedForm: Bool
    var budget: ANSILexingBudget

    /// 业务作用：同源词法类别、物理行和原生关键字顺序共同决定折叠层级，末尾无结束符的行保留原生默认状态。
    /// 参数说明: 无。
    /// 返回：完整原生行层级；正文、行数、类别、层级或共同预算不足时拒绝全部结果。
    mutating func levels() throws -> [Int] {
        guard bytes.count <= 64 * 1024 * 1024, styles.count == bytes.count,
            starts.first == 0, starts.count <= 1_048_576
        else {
            throw NateError.message("Fortran 折叠超过正文或物理行预算。")
        }
        try budget.check()
        let actualCount = bytes.count > 0 && starts.last == bytes.count ? starts.count - 1 : starts.count
        var comments: [Int?] = []
        for row in starts.indices {
            try budget.consume()
            guard starts[row] >= 0, starts[row] <= bytes.count,
                row == 0 || starts[row] > starts[row - 1]
            else {
                throw NateError.invalidRange
            }
            comments.append(row < actualCount ? try commentColumn(row: row) : nil)
        }
        var output = Array(repeating: 1024, count: starts.count)
        var visible = 0, line = 0, level = 1024, pending = 0, lastStart = 0
        var previous = ""
        var previousStyle: UInt8 = 0
        for index in bytes.indices {
            try budget.consume()
            let value = bytes[index], following = try byte(at: index + 1)
            var nextNonblank = following
            var nextEOL = nextNonblank == 10 || nextNonblank == 13
            var offset = index + 1
            while FortranCharacters.blank(UInt32(nextNonblank)), offset < bytes.count {
                offset += 1
                nextNonblank = try byte(at: offset)
                if nextNonblank == 13 || nextNonblank == 10 {
                    nextEOL = true
                }
            }
            if !nextEOL, offset == bytes.count {
                nextEOL = true
            }
            let style = styles[index]
            guard style <= 14 else {
                throw NateError.invalidRange
            }
            if (fixedForm && previousStyle == 14 || previousStyle == 0 || previousStyle == 6),
                style == 8 || style == 13
            {
                lastStart = index
            }
            if style == 8, Self.word(value), !Self.word(following) {
                let word = try name(from: lastStart, through: index)
                if word == "forall" || word == "where" && previous != "else" {
                    if previous != "end" {
                        pending += try conditionalDelta(after: index, row: line, actualRows: actualCount)
                    }
                }
                else {
                    let delta = FortranFoldWords.delta(word, previous: previous, following: nextNonblank)
                    pending += delta
                    if word == "else" && (nextEOL || nextNonblank == 33)
                        || previous == "else" && word == "where" || word == "elsewhere"
                    {
                        level -= 1
                        pending += 1
                    }
                    else if previous == "else" && word == "if" || word == "elseif" {
                        level -= 1
                    }
                    else if previous == "select" && ["case", "type", "rank"].contains(word)
                        || ["selectcase", "selecttype"].contains(word)
                    {
                        pending += 2
                    }
                    else if word == "case" && nextNonblank == 40 || previous == "case" && word == "default"
                        || ["type", "class"].contains(previous) && word == "is"
                        || previous == "class" && word == "default"
                    {
                        level -= 1
                        pending += 1
                    }
                    else if previous == "end" && word == "select" || word == "endselect" {
                        pending -= 2
                    }
                    if word == "do", FortranCharacters.digit(UInt32(nextNonblank)) {
                        pending -= delta
                    }
                }
                previous = word
            }
            if value == 13 && following != 10 || value == 10 {
                pending += try commentDelta(row: line, columns: comments, actualRows: actualCount)
                // 层级和当前真实行均确认后才写入候选，异常闭合或深度不能产生部分可见折叠。
                guard output.indices.contains(line), (0...4095).contains(level),
                    (0...4095).contains(level + pending)
                else {
                    throw NateError.message("Fortran 折叠层级超出 0–4095。")
                }
                output[line] = level | (pending > 0 && visible > 0 ? 8192 : 0)
                line += 1
                level += pending
                pending = 0
                visible = 0
                previous = ""
            }
            if !FortranCharacters.space(UInt32(value)) {
                visible += 1
            }
            previousStyle = style
        }
        try budget.check()
        return output
    }
}
