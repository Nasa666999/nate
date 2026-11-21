import Foundation

struct ErrorListRecognition {
    let bytes: [UInt8]
    var budget: ANSILexingBudget

    /// 业务作用：按固定诊断优先级区分日志来源，不从彩色文字或普通井号推断代码注释。
    /// 参数说明: 无。
    /// 返回：当前完整物理行的诊断样式编号；全部查找共享同一工作量与截止。
    mutating func style() throws -> Int {
        guard let first = bytes.first else {
            return 0
        }
        switch first {
        case 62: return 4
        case 60: return 12
        case 33: return 10
        case 43: return try prefix("+++ ") ? 13 : 11
        case 45: return try prefix("--- ") ? 13 : 12
        default: break
        }
        if try prefix("cf90-") {
            return 18
        }
        if try prefix("fortcom:") {
            return 17
        }
        if try contains("File \"") && contains(", line ") {
            return 1
        }
        if try contains(" in ") && contains(" on line ") {
            return 14
        }
        let error = try prefix("Error ")
        let warning = try prefix("Warning ")
        if error || warning {
            return try ordered(" at (", ") : ") ? 16 : 5
        }
        if try contains("at line ") && contains("file ") {
            return 8
        }
        if try ordered(" at ", " line ") {
            return 6
        }
        if try prefix("   at ") && contains(":line ") {
            return 7
        }
        if try prefix("Line ") && contains(", file ") {
            return 15
        }
        if try prefix("line ") && contains(" column ") {
            return 19
        }
        if try prefix("\tat ") && contains("(") && contains(".java:") {
            return 20
        }
        if try prefix("In file included from ") || prefix("                 from ") {
            return 22
        }
        if try prefix("NMAKE : fatal error") || contains("warning LNK") || contains("error LNK") {
            return 3
        }
        if try bash() {
            return 26
        }
        if try excerpt() {
            return 25
        }
        return try location()
    }

    /// 业务作用：诊断前缀按原字节区分大小写，Unicode 规范等价关系不改变日志类别。
    /// 参数说明:
    /// - text: 固定 ASCII 前缀。
    /// 返回：完整前缀匹配时为真，所有实际比较计入共同预算。
    mutating func prefix(_ text: String) throws -> Bool {
        let pattern = Array(text.utf8)
        guard bytes.count >= pattern.count else {
            return false
        }
        for index in pattern.indices {
            try budget.consume()
            if bytes[index] != pattern[index] {
                return false
            }
        }
        return true
    }

    /// 业务作用：有界查找诊断标记，正文中的 NUL 不截断非终端诊断规则。
    /// 参数说明:
    /// - text: 固定 ASCII 诊断标记。
    /// - start: 当前查找起点。
    /// 返回：第一个完整匹配起点；没有匹配时为空，超预算抛错。
    mutating func find(_ text: String, start: Int = 0) throws -> Int? {
        let pattern = Array(text.utf8)
        guard start >= 0, start <= bytes.count, pattern.count <= bytes.count - start else {
            return nil
        }
        for offset in start...(bytes.count - pattern.count) {
            var matched = true
            for index in pattern.indices {
                try budget.consume()
                if bytes[offset + index] != pattern[index] {
                    matched = false
                    break
                }
            }
            if matched {
                return offset
            }
        }
        return nil
    }

    /// 业务作用：完整诊断短语存在才取得对应类别，不截断或改写日志文字。
    /// 参数说明:
    /// - text: 固定诊断标记。
    /// 返回：找到标记时为真，工作量不足时整体拒绝。
    mutating func contains(_ text: String) throws -> Bool {
        try find(text) != nil
    }

    /// 业务作用：确认日志的两个结构标记按规定顺序出现，反向排列不冒充诊断。
    /// 参数说明:
    /// - first: 前置标记。
    /// - second: 必须位于前置标记之后的标记。
    /// 返回：两个完整标记有有效先后关系时为真。
    mutating func ordered(_ first: String, _ second: String) throws -> Bool {
        guard let start = try find(first) else {
            return false
        }
        return try find(second, start: start + first.utf8.count) != nil
    }

    /// 业务作用：Bash 行号标记必须包含真实十进制数字及末尾冒号。
    /// 参数说明: 无。
    /// 返回：首个 Bash 标记具有完整行号时为真。
    mutating func bash() throws -> Bool {
        guard let start = try find(": line ") else {
            return false
        }
        var cursor = start + 7
        let digits = cursor
        while cursor < bytes.count, Self.digit(bytes[cursor]) {
            try budget.consume()
            cursor += 1
        }
        return cursor > digits && cursor < bytes.count && bytes[cursor] == 58
    }

    /// 业务作用：GCC 摘录只接受受约束的行号与竖线前缀，任意代码文字不被误认。
    /// 参数说明: 无。
    /// 返回：完整摘录标记或未结束的合法空前缀时为真。
    mutating func excerpt() throws -> Bool {
        for index in bytes.indices {
            try budget.consume()
            let byte = bytes[index]
            if byte == 32, index + 2 < bytes.count, bytes[index + 1] == 124,
                bytes[index + 2] == 32 || bytes[index + 2] == 43
            {
                return true
            }
            if byte != 32 && byte != 43 && !Self.digit(byte) {
                return false
            }
        }
        return true
    }

    private enum LocationState {
        case initial, gccStart, gccDigit, gccColumn, gcc
        case msStart, msDigit, msBracket, microsoft, msComma, dotnet
        case ctagsStart, ctagsFile, ctagsString, ctagsDollar, ctags, rejected
    }

    /// 业务作用：通过有限状态确认文件、行列号与 ctags 定位格式，避免用宽泛正则吞并普通日志。
    /// 参数说明: 无。
    /// 返回：GCC、Microsoft、Lua 或 ctags 类别；不完整或不适用的格式返回默认样式。
    mutating func location() throws -> Int {
        let initialTab = bytes.first == 9
        var initialColon = false
        var canBeCtags = !initialTab
        var state = LocationState.initial
        outer: for index in bytes.indices {
            try budget.consume()
            let byte = bytes[index]
            let next: UInt8 = index + 1 < bytes.count ? bytes[index + 1] : 32
            switch state {
            case .initial:
                if byte == 58 {
                    if next != 92 && next != 47 && next != 32 {
                        state = .gccStart
                    }
                    else if next == 32 {
                        initialColon = true
                    }
                }
                else if byte == 40, next >= 49 && next <= 57, !initialTab {
                    state = .msStart
                }
                else if byte == 9 && canBeCtags {
                    state = .ctagsStart
                }
                else if byte == 32 {
                    canBeCtags = false
                }
            case .gccStart:
                state = byte == 45 || Self.digit(byte) ? .gccDigit : .rejected
            case .gccDigit:
                if byte == 58 {
                    state = .gccColumn
                }
                else if !Self.digit(byte) {
                    state = .rejected
                }
            case .gccColumn:
                if !Self.digit(byte) {
                    state = .gcc
                    break outer
                }
            case .msStart:
                state = Self.digit(byte) ? .msDigit : .rejected
            case .msDigit:
                if byte == 44 {
                    state = .msComma
                }
                else if byte == 41 {
                    state = .msBracket
                }
                else if byte != 32 && !Self.digit(byte) {
                    state = .rejected
                }
            case .msBracket:
                if byte == 32 && next == 58 {
                    state = .microsoft
                }
                else if byte == 58 && next == 32 || byte == 32 {
                    var cursor = index + (byte == 32 ? 1 : 2)
                    guard cursor <= bytes.count else {
                        state = .rejected
                        continue
                    }
                    let start = cursor
                    while cursor < bytes.count, Self.letter(bytes[cursor]) {
                        try budget.consume()
                        cursor += 1
                    }
                    let word = bytes[start..<cursor].map {
                        $0 >= 65 && $0 <= 90 ? $0 + 32 : $0
                    }
                    state =
                        ["error", "warning", "fatal", "catastrophic", "note", "remark"].contains(
                            String(decoding: word, as: UTF8.self)
                        ) ? .microsoft : .rejected
                }
                else {
                    state = .rejected
                }
            case .msComma:
                if byte == 41 {
                    state = .dotnet
                    break outer
                }
                if byte != 32 && !Self.digit(byte) {
                    state = .rejected
                }
            case .ctagsStart:
                if byte == 9 {
                    state = .ctagsFile
                }
            case .ctagsFile:
                if index > 0, bytes[index - 1] == 9, byte == 47 && next == 94 || Self.digit(byte) {
                    state = .ctags
                    break outer
                }
                else if byte == 47 && next == 94 {
                    state = .ctagsString
                }
            case .ctagsString:
                if byte == 36 && next == 47 {
                    state = .ctagsDollar
                    break outer
                }
            default:
                break
            }
        }
        switch state {
        case .gcc: return initialColon ? 8 : 2
        case .microsoft, .dotnet: return 3
        case .ctagsDollar, .ctags: return 9
        default: return try initialColon && contains(": warning C") ? 3 : 0
        }
    }

    /// 业务作用：日志行列号只使用协议规定的 ASCII 数字。
    /// 参数说明:
    /// - byte: 原始字节。
    /// 返回：属于十进制数字时为真。
    private static func digit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// 业务作用：Microsoft 诊断级别只取连续 ASCII 字母，不吞入级别后的编号或正文。
    /// 参数说明:
    /// - byte: 原始字节。
    /// 返回：属于 ASCII 字母时为真。
    private static func letter(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }
}
