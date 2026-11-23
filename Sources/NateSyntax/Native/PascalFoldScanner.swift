import Foundation
import NateCore

struct PascalFoldScanner {
    let bytes: [UInt8]
    let styles: [UInt8]
    let starts: [Int]
    var budget: ANSILexingBudget
    var levelPrevious = 1024
    var levelCurrent = 1024
    var preprocessorDepth: UInt32 = 0
    var inPreprocessor = false
    var inRecord = false

    /// 业务作用：Pascal 折叠只使用完整词法类别与物理行，预处理启用时不把其中可选代码分支误合并为代码块。
    /// 参数说明: 无。
    /// 返回：每个物理行的完整原生非紧凑层级；证据、步骤或截止不足时拒绝整份层级。
    mutating func levels() throws -> [Int] {
        guard bytes.count == styles.count, starts.first == 0 else {
            throw NateError.invalidRange
        }
        var levels = Array(repeating: 1024, count: starts.count)
        var line = 0
        var previous: UInt8 = 0
        var visible = 0
        var lastStart = 0
        for index in bytes.indices {
            try budget.consume()
            let current = bytes[index], following = byte(index + 1)
            let style = styles[index], nextStyle = styleAt(index + 1)
            let lineEnd = current == 13 && following != 10 || current == 10
            if stream(style) {
                if !stream(previous) {
                    levelCurrent += 1
                }
                else if !stream(nextStyle), !lineEnd {
                    levelCurrent -= 1
                }
            }
            if lineEnd, try commentLine(line) {
                let before = try commentLine(line - 1)
                let after = try commentLine(line + 1)
                if !before, after {
                    levelCurrent += 1
                }
                else if before, !after {
                    levelCurrent -= 1
                }
            }
            if style == 5, current == 123, following == 36 {
                try preprocessor(at: index + 2)
            }
            else if style == 6, current == 40, following == 42, byte(index + 2) == 36 {
                try preprocessor(at: index + 3)
            }
            if previous != 9, style == 9 {
                lastStart = index
            }
            if previous == 9, !inPreprocessor,
                PascalCharacters.word(current), !PascalCharacters.word(following)
            {
                try codeWord(start: lastStart, end: index)
            }
            if current != 32, !(9...13).contains(current) {
                visible += 1
            }
            // 层级超出原生可完整表示范围后不能把高位当作折叠标志，整份保留正文可见。
            guard (0...4095).contains(levelCurrent) else {
                throw NateError.message("Pascal 折叠层级超过完整可表示范围。")
            }
            if lineEnd {
                var level = levelPrevious
                if levelCurrent > levelPrevious, visible > 0 {
                    level |= 8192
                }
                guard line < levels.count else {
                    throw NateError.invalidRange
                }
                levels[line] = level
                line += 1
                levelPrevious = levelCurrent
                visible = 0
            }
            previous = style
        }
        guard line < levels.count else {
            throw NateError.invalidRange
        }
        levels[line] = levelPrevious
        try budget.check()
        return levels
    }

    /// 业务作用：预处理层级保持原生八位嵌套证据，关闭指令只在完整匹配时回收代码折叠资格。
    /// 参数说明:
    /// - start: 当前指令名的真实原字节起点。
    /// 返回：完整开闭指令推进层级，其它指令保持原状态。
    mutating func preprocessor(at start: Int) throws {
        let word = try forwardWord(at: start, maximum: 10, digits: false)
        if ["if", "ifdef", "ifndef", "ifopt", "region"].contains(word) {
            let nesting = preprocessorDepth + 1
            preprocessorDepth = nesting & 255
            inPreprocessor = true
            levelCurrent += 1
        }
        else if ["endif", "ifend", "endregion"].contains(word) {
            let nesting = preprocessorDepth &- 1
            preprocessorDepth = nesting & 255
            if nesting == 0 {
                inPreprocessor = false
            }
            levelCurrent = max(1024, levelCurrent - 1)
        }
    }

    /// 业务作用：代码块关键字保留 record 变体、前向声明及类方法的原生例外，未确认的声明不猜测结束范围。
    /// 参数说明:
    /// - start: 当前完整关键字的起点。
    /// - end: 包含在内的最后原字节。
    /// 返回：完整声明证据改变原生层级；普通关键字保持原层级。
    mutating func codeWord(start: Int, end: Int) throws {
        let finish = min(end + 1, start + 99)
        let word = String(decoding: bytes[start..<finish].map(PascalCharacters.folded), as: UTF8.self)
        if word == "record" {
            inRecord = true
            levelCurrent += 1
        }
        else if ["begin", "asm", "try"].contains(word) || word == "case" && !inRecord {
            levelCurrent += 1
        }
        else if word == "class" || word == "object" {
            var ignored = false
            var next = try skip(after: end)
            if next < bytes.count {
                if byte(next) == 59 {
                    ignored = true
                }
                else if word == "class" {
                    if byte(next) == 40 {
                        next = try skip(after: next, includeNames: true)
                        if next < bytes.count, byte(next) == 41 {
                            next = try skip(after: next)
                            ignored = next < bytes.count && byte(next) == 59
                        }
                    }
                    else if asciiWordStart(byte(next)) {
                        let second = try forwardWord(at: next, maximum: 10, digits: true)
                        ignored = ["procedure", "function", "of", "var", "property", "operator"].contains(
                            second
                        )
                    }
                }
            }
            if !ignored {
                levelCurrent += 1
            }
        }
        else if word == "interface" {
            var previous = start - 1
            while previous >= 0 {
                try budget.consume()
                let value = byte(previous)
                if value == 9 || value == 32 || value == 13 || value == 10 || stream(styleAt(previous)) {
                    previous -= 1
                }
                else {
                    break
                }
            }
            if previous >= 0, byte(previous) == 61 {
                let next = try skip(after: end)
                if next >= bytes.count || byte(next) != 59 {
                    levelCurrent += 1
                }
            }
        }
        else if word == "dispinterface" {
            let next = try skip(after: end)
            if next >= bytes.count || byte(next) != 59 {
                levelCurrent += 1
            }
        }
        else if word == "end" {
            inRecord = false
            levelCurrent = max(1024, levelCurrent - 1)
        }
    }
}
