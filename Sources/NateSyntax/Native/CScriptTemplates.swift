import Foundation
import NateCore

extension CLexing {
    /// 业务作用：真实文件末尾的未闭合普通引号使用完整错误类别，同时保留插入点仍在字面内的保护证据。
    /// 参数说明: 无。
    /// 返回：当前物理范围的未完成字面已统一分类；显示片段边界和其它共享语言不提前结束字面。
    mutating func finishScriptDocument() throws {
        guard scriptRules != nil, state.quote != nil, !state.header, !skippedScriptEnd,
            bytes.last != 10, bytes.last != 13,
            snapshot.map({
                base + bytes.count == $0.text.byteCount
            }) ?? true
        else {
            return
        }
        _ = try reclassifyScriptLiteral("invalid")
    }

    /// 业务作用：JavaScript 原始字面区分转义与模板表达式，TypeScript 沿自己的原始反引号规则处理。
    /// 参数说明: 无。
    /// 返回：完整消费模板转义或表达式开端时为真，其它位置继续既有原始字面读取。
    mutating func scriptTemplateByte() throws -> Bool {
        guard scriptRules?.interpolatesTemplates == true else {
            return false
        }
        let current = bytes[cursor]
        if current == 92 {
            var end = cursor + 1
            if end < bytes.count {
                let first = bytes[end]
                end += first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
            }
            try emit(cursor, min(end, bytes.count), kind: .string, style: "raw")
            cursor = min(end, bytes.count)
            return true
        }
        guard current == 36, cursor + 1 < bytes.count, bytes[cursor + 1] == 123 else {
            return false
        }
        // 每一层都持有返回字面区的资格，超量时不能只保留部分表达式栈并继续授权代码标点。
        guard state.templateDepths.count < 256 else {
            throw NateError.message("JavaScript 模板表达式超过 256 层。")
        }
        state.templateDepths.append(1)
        state.templateDelimiter = state.rawEnding
        try emitCode(cursor, cursor + 2, kind: .punctuation, style: "punctuation")
        cursor += 2
        state.rawEnding = []
        state.rawMatched = 0
        state.rawVisibleBeforeMatch = nil
        return true
    }

    /// 业务作用：模板表达式只由真实代码花括号计数，字符串、注释及正则中的符号不改变返回资格。
    /// 参数说明:
    /// - byte: 已确认处于代码区的当前原字节。
    /// 返回：表达式闭合并恢复字面读取时为真；普通标点为假，超量时拒绝整行状态。
    mutating func closeScriptExpression(_ byte: UInt8) throws -> Bool {
        guard scriptRules?.interpolatesTemplates == true, !state.templateDepths.isEmpty,
            byte == 123 || byte == 125
        else {
            return false
        }
        let top = state.templateDepths.count - 1
        state.templateDepths[top] += byte == 123 ? 1 : -1
        guard state.templateDepths[top] <= 4096 else {
            throw NateError.message("JavaScript 模板中的代码花括号超过 4096 层。")
        }
        guard state.templateDepths[top] == 0 else {
            return false
        }
        try emitCode(cursor, cursor + 1, kind: .punctuation, style: "punctuation")
        cursor += 1
        state.templateDepths.removeLast()
        state.rawEnding = state.templateDelimiter
        state.rawMatched = 0
        state.rawVisibleBeforeMatch = nil
        return true
    }

    /// 业务作用：脚本预处理体使用独立原生类别，引用内部的注释标记不能开启业务代码或注释状态。
    /// 参数说明: 无。
    /// 返回：完整消费预处理字节或真实行尾时为真；注释开端交回统一注释流程，其它语言为假。
    mutating func scriptPreprocessorByte() throws -> Bool {
        guard scriptRules != nil, state.preprocessor else {
            return false
        }
        let current = bytes[cursor]
        let ending = newlineWidth(at: cursor)
        if ending > 0 {
            try emit(cursor, cursor + ending, kind: .keyword, style: "preprocessor")
            endLogicalLine()
            cursor += ending
            return true
        }
        if state.scriptPreprocessorQuote {
            if current == 34 || current == 62 {
                state.scriptPreprocessorQuote = false
            }
        }
        else if current == 34 || current == 60 && state.expectsHeader {
            state.scriptPreprocessorQuote = true
        }
        else if current == 47, cursor + 1 < bytes.count,
            bytes[cursor + 1] == 47 || bytes[cursor + 1] == 42
        {
            return false
        }
        if state.directiveWord {
            if Self.wordPart(current), state.directivePrefix.utf8.count < 64 {
                state.directivePrefix.append(Character(UnicodeScalar(current)))
                state.expectsHeader = state.directivePrefix.hasPrefix("include")
            }
            else if !state.directivePrefix.isEmpty || ![9, 32].contains(current) {
                state.directiveWord = false
                state.expectsHeader = state.directivePrefix.hasPrefix("include")
            }
        }
        try emit(cursor, cursor + 1, kind: .keyword, style: "preprocessor")
        cursor += 1
        return true
    }
}
