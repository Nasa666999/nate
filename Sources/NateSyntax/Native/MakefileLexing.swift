import Foundation
import NateCore

extension PropertyLexing {
    /// 业务作用：区分 Makefile 的命令行、目标、赋值与变量引用，所有命令文字只用于呈现。
    /// 参数说明:
    /// - start: 当前完整物理行的原始起点。
    /// - end: 包含真实结束符的末边界。
    /// 返回：保留列首 Tab 与嵌套引用语义的完整有限词元，不执行构建或展开变量。
    mutating func makeLine(_ start: Int, _ end: Int) throws {
        let row = Array(bytes[start..<end])
        let command = row.first == 9
        var cursor = 0
        while cursor < row.count, Self.space(row[cursor]) {
            try budget.consume()
            cursor += 1
        }
        if cursor < row.count, row[cursor] == 35 || row[cursor] == 33 {
            try emit(start, end, style: row[cursor] == 35 ? 1 : 2)
            return
        }
        var painter = MakeLinePainter(
            classes: Array(repeating: 0, count: row.count),
            budget: budget
        )
        if cursor < row.count, !directives.isEmpty, MakeLinePainter.letter(row[cursor]) {
            var assignment = false
            for byte in row {
                try painter.budget.consume()
                if byte == 58 || byte == 61 {
                    assignment = true
                    break
                }
            }
            if !assignment {
                var finish = cursor
                while finish < row.count, MakeLinePainter.letter(row[finish]) {
                    try painter.budget.consume()
                    finish += 1
                }
                var known = false
                for directive in directives {
                    try painter.budget.consume()
                    guard directive.utf8.count == finish - cursor else {
                        continue
                    }
                    var index = cursor
                    var equal = true
                    for byte in directive.utf8 {
                        try painter.budget.consume()
                        if row[index] != byte {
                            equal = false
                            break
                        }
                        index += 1
                    }
                    if equal {
                        known = true
                        break
                    }
                }
                if known {
                    try painter.colour(to: finish - 1, style: 2)
                    cursor = finish
                }
            }
        }
        var state: UInt8 = 0
        var depth = 0
        var previous: UInt8 = 0
        var lastNonSpace = -1
        var special = false
        while cursor < row.count {
            try painter.budget.consume()
            let byte = row[cursor]
            if byte == 35, !command, depth == 0, previous != 92 {
                try painter.colour(to: cursor - 1, style: state)
                try painter.colour(to: row.count - 1, style: 1)
                break
            }
            else if byte == 36, cursor + 1 < row.count, row[cursor + 1] == 40 {
                try painter.colour(to: cursor - 1, style: state)
                state = 3
                depth += 1
            }
            else if state == 3, byte == 41 {
                depth -= 1
                if depth == 0 {
                    try painter.colour(to: cursor, style: state)
                    state = 0
                }
            }
            if !special, !command, byte == 58 || byte == 61 {
                let immediate = byte == 58 && cursor + 1 < row.count && row[cursor + 1] == 61
                if lastNonSpace >= 0 {
                    try painter.colour(to: lastNonSpace, style: byte == 58 && !immediate ? 5 : 3)
                }
                try painter.colour(to: cursor - 1, style: 0)
                try painter.colour(to: cursor + (immediate ? 1 : 0), style: 4)
                special = true
                state = 0
            }
            if !Self.space(byte) {
                lastNonSpace = cursor
            }
            previous = byte
            cursor += 1
        }
        try painter.colour(to: row.count - 1, style: state == 3 ? 9 : 0)
        budget = painter.budget
        guard let first = painter.classes.first else {
            return
        }
        var run = 0
        var identity = first
        for offset in 1...row.count {
            try budget.consume()
            if offset == row.count || painter.classes[offset] != identity {
                try emit(start + run, start + offset, style: Int(identity))
                if offset < row.count {
                    run = offset
                    identity = painter.classes[offset]
                }
            }
        }
    }
}

struct MakeLinePainter {
    var classes: [UInt8]
    var budget: ANSILexingBudget
    private var position = 0

    /// 业务作用：单行暂存样式受原行容量约束，完整分类之前不向视图发布。
    /// 参数说明:
    /// - classes: 与原始单行逐字节对应的有限分类暂存。
    /// - budget: 包含来源读取及行扫描消耗的共同预算。
    /// 返回：从行首开始的单次前向样式写入器。
    init(classes: [UInt8], budget: ANSILexingBudget) {
        self.classes = classes
        self.budget = budget
    }

    /// 业务作用：只推进尚未分类的原字节，目标或引用不能回写已完成的前置词元。
    /// 参数说明:
    /// - end: 包含的行内末字节，早于当前位置时不改变既有范围。
    /// - style: 当前完整范围采用的原始样式编号。
    /// 返回：有限前向范围全部分类，取消或超时抛错并舍弃整行。
    mutating func colour(to end: Int, style: UInt8) throws {
        guard end >= position else {
            return
        }
        guard end < classes.count else {
            throw NateError.invalidRange
        }
        while position <= end {
            try budget.consume()
            classes[position] = style
            position += 1
        }
    }

    /// 业务作用：Makefile 指令候选按 ASCII 字母截取，非 ASCII 名称仍保留原始目标或值身份。
    /// 参数说明:
    /// - byte: 当前源字节。
    /// 返回：属于 ASCII 字母时为真。
    static func letter(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }
}
