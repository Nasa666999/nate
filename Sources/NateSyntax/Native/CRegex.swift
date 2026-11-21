import Foundation
import NateCore

extension CLexing {
    /// 业务作用：共享 C 词法只在明确前置标点或本行 return 后识别有闭合证据的斜线字面量。
    /// 参数说明: 无。
    /// 返回：建立正则字面量状态时为真；注释、预处理体、后缀自增减或缺少本行闭合证据时保持代码解释。
    mutating func beginRegex() throws -> Bool {
        guard bytes[cursor] == 47, !state.preprocessor else {
            return false
        }
        let allowed = "([{=,:;!%^&*|?~+-> ".utf8.contains(state.previousNonWhite)
        guard try allowed || followsRegexReturn() else {
            return false
        }
        guard ![43, 45].contains(state.previousNonWhite) || !state.lastAddWasDoubled else {
            return false
        }
        guard try hasRegexClosingEvidence() else {
            return false
        }
        state.regex = true
        state.regexClass = false
        state.regexEscape = false
        try emit(cursor, cursor + 1, kind: .string, style: "regex")
        cursor += 1
        return true
    }

    /// 业务作用：字面量中的括号与斜线由字符类和转义状态消费，不参与主代码结构。
    /// 参数说明: 无。
    /// 返回：消费一个字面或标志片段时为真；标志结束后把当前字节交还普通代码流程。
    mutating func regexByte() throws -> Bool {
        let byte = bytes[cursor]
        if state.regexFlags {
            guard byte >= 97, byte <= 122 else {
                state.regexFlags = false
                return false
            }
            try emit(cursor, cursor + 1, kind: .string, style: "regex", updatesContext: false)
            cursor += 1
            return true
        }
        let ending = newlineWidth(at: cursor)
        if ending > 0 {
            try emit(cursor, cursor + ending, kind: .string, style: "regex", updatesContext: false)
            cursor += ending
            endLogicalLine()
            return true
        }
        var updatesContext = true
        if state.regexEscape {
            state.regexEscape = false
        }
        else if byte == 47, !state.regexClass {
            state.regex = false
            state.regexFlags = true
            // 闭合斜线与标志在同一步消费，下一候选沿用字面内部最后实际处理的非空白字符。
            updatesContext = false
        }
        else if byte == 92 {
            state.regexEscape = true
        }
        else if byte == 91 {
            state.regexClass = true
        }
        else if byte == 93 {
            state.regexClass = false
        }
        try emit(cursor, cursor + 1, kind: .string, style: "regex", updatesContext: updatesContext)
        cursor += 1
        return true
    }

    /// 业务作用：return 证据只读取同一物理行的原始字节，不从已着色词元猜测语法树。
    /// 参数说明: 无。
    /// 返回：跳过空格和 Tab 后，当前位置前的原字节以 return 结尾时为真；超过 1 MiB 不返回猜测。
    private mutating func followsRegexReturn() throws -> Bool {
        var offset = cursor - 1
        var count = 0
        while let byte = regexSourceByte(at: offset), byte == 32 || byte == 9 {
            try budget.consume()
            guard count < 1_048_576 else {
                throw NateError.message("C/C++ 正则起点的原始前文超过 1 MiB。")
            }
            count += 1
            offset -= 1
        }
        for expected in "nruter".utf8 {
            try budget.consume()
            guard count < 1_048_576 else {
                throw NateError.message("C/C++ 正则起点的原始前文超过 1 MiB。")
            }
            count += 1
            guard regexSourceByte(at: offset) == expected else {
                return false
            }
            offset -= 1
        }
        return true
    }

    /// 业务作用：先取得本物理行中另一斜线的原始证据，再允许进入正则保护范围。
    /// 参数说明: 无。
    /// 返回：1 MiB 以内存在后续斜线时为真，物理行末或正文末尾没有证据时为假；超限整体失败。
    private mutating func hasRegexClosingEvidence() throws -> Bool {
        var offset = cursor + 1
        var count = 0
        while let byte = regexSourceByte(at: offset) {
            try budget.consume()
            guard count < 1_048_576 else {
                throw NateError.message("C/C++ 正则闭合证据超过本行 1 MiB 范围。")
            }
            if byte == 47 {
                return true
            }
            if byte == 10 || byte == 13 {
                return false
            }
            count += 1
            offset += 1
        }
        return false
    }

    /// 业务作用：显示分段与物理行使用同一快照中的前后文字节，本地片段不冒充正文末尾。
    /// 参数说明:
    /// - offset: 相对当前片段起点的位置，允许有界前后文读取。
    /// 返回：固定源中的真实字节；没有完整快照且超出本片段时为空。
    private func regexSourceByte(at offset: Int) -> UInt8? {
        if offset >= 0, offset < bytes.count {
            return bytes[offset]
        }
        guard offset >= -base, offset <= Int.max - base else {
            return nil
        }
        return snapshot?.text.byte(at: base + offset)
    }
}
