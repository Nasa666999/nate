import NateCore

enum MakefileIndentationSyntax {
    enum Event {
        case neutral
        case conditional
        case alternative(final: Bool)
        case endConditional
        case definition
        case endDefinition
    }

    enum RecipePrefix {
        case unchanged
        case known(UInt8)
        case unresolved
    }

    enum RecipeContext {
        case unchanged
        case afterRule
        case outsideRule
    }

    private static let conditions: Set<String> = ["ifdef", "ifndef", "ifeq", "ifneq"]
    private static let definitionModifiers: Set<String> = ["override", "export", "private"]
    private static let ruleEndDirectives: Set<String> = [
        "include", "sinclude", "export", "unexport", "vpath", "undefine",
    ]

    /// 业务作用：识别 GNU Make 的实际条件与多行定义指令，名称前缀、赋值及定义正文不取得块资格。
    /// 参数说明:
    /// - input: 同一逻辑语句已拼接的完整原字节。
    /// - definition: 当前位于 define 的原始变量值内时为真。
    /// - check: 本次整批换行的继续资格。
    /// 返回：完成的指令角色；内容、注释或语法证据不足时为中性。
    static func event(
        _ input: ArraySlice<UInt8>,
        insideDefinition definition: Bool,
        check: () throws -> Void
    ) throws -> Event {
        var source = try code(input, check: check)
        let first = word(from: &source)
        if first == "endef" {
            return source.isEmpty ? .endDefinition : .neutral
        }
        if definition {
            // GNU Make 在原始 define 值内只把直接的 define 识别为嵌套边界。
            return first == "define" ? .definition : .neutral
        }
        var name = first
        while let modifier = name, definitionModifiers.contains(modifier) {
            try check()
            name = word(from: &source)
        }
        if name == "define" {
            return try definesVariable(source, check: check) ? .definition : .neutral
        }
        guard let first else {
            return .neutral
        }
        if conditions.contains(first) {
            return try condition(first, operands: source, check: check) ? .conditional : .neutral
        }
        if first == "endif" {
            return source.isEmpty ? .endConditional : .neutral
        }
        if first == "else" {
            if source.isEmpty {
                return .alternative(final: true)
            }
            guard let nested = word(from: &source), conditions.contains(nested),
                try condition(nested, operands: source, check: check)
            else {
                return .neutral
            }
            return .alternative(final: false)
        }
        return .neutral
    }

    /// 业务作用：使用真实转义和变量引用边界识别 Make 注释，引用内部的井号仍是原参数。
    /// 参数说明:
    /// - input: 当前完整逻辑语句字节范围。
    /// - check: 共享输入的继续资格。
    /// 返回：首个有效注释之前去掉水平首尾空白的代码范围。
    static func code(_ input: ArraySlice<UInt8>, check: () throws -> Void) throws -> ArraySlice<UInt8> {
        let end = try commentStart(input, check: check) ?? input.endIndex
        return trim(input[..<end])
    }

    /// 业务作用：保留逻辑语句真实注释开端，物理续接保持注释资格。
    /// 参数说明:
    /// - input: 原始完整逻辑语句。
    /// - check: 所有光标共用的继续资格。
    /// 返回：实际独立井号的绝对索引，无注释时为空。
    static func commentStart(_ input: ArraySlice<UInt8>, check: () throws -> Void) throws -> Int? {
        try unquoted(in: input, stoppingAt: [35], check: check)
    }

    /// 业务作用：规则分隔符与注释共用同一原字节词法，引用参数及转义不会打开外层规则。
    /// 参数说明:
    /// - input: 已拼接的完整逻辑行。
    /// - stops: 当前调用实际关注的外层分隔符。
    /// - check: 所有光标共用的继续资格。
    /// 返回：首个有效外层分隔符的绝对位置。
    private static func unquoted(
        in input: ArraySlice<UInt8>,
        stoppingAt stops: Set<UInt8>,
        check: () throws -> Void
    ) throws -> Int? {
        var expected: [UInt8] = []
        var index = input.startIndex
        while index < input.endIndex {
            try check()
            let byte = input[index]
            if byte == 92, index + 1 < input.endIndex {
                index += 2
                continue
            }
            if byte == 36, index + 1 < input.endIndex,
                let close = closing(for: input[index + 1])
            {
                guard expected.count < 4096 else {
                    throw NateError.message("Makefile 变量引用超过 4096 层。")
                }
                expected.append(close)
                index += 2
                continue
            }
            if let last = expected.last {
                if last == byte {
                    expected.removeLast()
                }
                else if closing(for: byte) == last {
                    guard expected.count < 4096 else {
                        throw NateError.message("Makefile 变量引用超过 4096 层。")
                    }
                    expected.append(last)
                }
            }
            else if stops.contains(byte) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// 业务作用：在实际目标条目之后解释配方前缀，普通赋值及全局指令结束此前规则。
    /// 参数说明:
    /// - input: 已去除外层注释的完整 Make 代码。
    /// - check: 所有光标共用的继续资格。
    /// 返回：维持当前规则、建立可能的配方上下文或关闭已结束的规则。
    static func recipeContext(
        _ input: ArraySlice<UInt8>,
        check: () throws -> Void
    ) throws -> RecipeContext {
        var operands = input
        if let first = word(from: &operands), ruleEndDirectives.contains(first) {
            return .outsideRule
        }
        if input.starts(with: "-include ".utf8) || input.starts(with: "-include\t".utf8) {
            return .outsideRule
        }
        guard let separator = try unquoted(in: input, stoppingAt: [58, 59, 61], check: check) else {
            return .unchanged
        }
        switch input[separator] {
        case 61:
            return .outsideRule
        case 58:
            let tail = input[separator...]
            if [":=", "::=", ":::="].contains(where: { tail.starts(with: $0.utf8) }) {
                return .outsideRule
            }
            return .afterRule
        default:
            return .unchanged
        }
    }

    /// 业务作用：读取实际定义的常量配方前缀，变量求值或其它修改方式缺少证据时暂停结构处理。
    /// 参数说明:
    /// - input: 已定位到真实注释之前的完整 Make 代码。
    /// 返回：保持、重设默认 Tab、指定已确认的单字节前缀或标记表达式未确认。
    static func recipePrefix(_ input: ArraySlice<UInt8>) -> RecipePrefix {
        let name = ".RECIPEPREFIX"
        var remaining = input
        while true {
            var afterModifier = remaining
            guard let modifier = word(from: &afterModifier), definitionModifiers.contains(modifier) else {
                break
            }
            remaining = afterModifier
        }
        if remaining.starts(with: "undefine ".utf8) || remaining.starts(with: "undefine\t".utf8) {
            let target = trim(remaining.dropFirst("undefine".utf8.count))
            return target.elementsEqual(name.utf8) ? .known(9) : .unchanged
        }
        guard remaining.starts(with: name.utf8) else {
            return .unchanged
        }
        let tail = trim(remaining.dropFirst(name.utf8.count))
        guard let first = tail.first, [33, 43, 58, 61, 63].contains(first) else {
            return .unchanged
        }
        for symbol in [":::=", "::=", ":=", "="] where tail.starts(with: symbol.utf8) {
            let value = trim(tail.dropFirst(symbol.utf8.count))
            guard let prefix = value.first else {
                return .known(9)
            }
            // 赋值首字节独立于后续文本时可静态确认，包含引用或转义的前缀仍需保守处理。
            if (33...126).contains(prefix), ![35, 36, 92].contains(prefix) {
                return .known(prefix)
            }
            return .unresolved
        }
        return .unresolved
    }

    /// 业务作用：条件需要符合所属指令的完整表达式，更长的目标或赋值不会借用关键字。
    /// 参数说明:
    /// - name: 当前确切的小写条件指令。
    /// - operands: 已去除文本层注释的原始参数。
    /// - check: 本次输入的共同继续资格。
    /// 返回：具有完整比较式或变量名时为真。
    private static func condition(
        _ name: String,
        operands: ArraySlice<UInt8>,
        check: () throws -> Void
    ) throws -> Bool {
        if name == "ifdef" || name == "ifndef" {
            return try variableName(operands, check: check)
        }
        if operands.first == 40 {
            return try parenthesizedComparison(operands, check: check)
        }
        var remaining = operands
        for _ in 0..<2 {
            try check()
            guard let quote = remaining.first, quote == 34 || quote == 39 else {
                return false
            }
            var index = remaining.startIndex + 1
            while index < remaining.endIndex, remaining[index] != quote {
                try check()
                index += remaining[index] == 92 && index + 1 < remaining.endIndex ? 2 : 1
            }
            guard index < remaining.endIndex else {
                return false
            }
            remaining = trim(remaining[(index + 1)...])
        }
        return remaining.isEmpty
    }

    /// 业务作用：比较参数只有由真实外层逗号分隔时完整，嵌套函数或引用的逗号属于自己的内容。
    /// 参数说明:
    /// - input: 从左圆括号开始的整个操作数范围。
    /// - check: 全部语句共享的继续资格。
    /// 返回：存在首个外层逗号和可靠闭合端且行尾无多余代码时为真；后续逗号属于第二个值。
    private static func parenthesizedComparison(
        _ input: ArraySlice<UInt8>,
        check: () throws -> Void
    ) throws -> Bool {
        var expected: [UInt8] = [41]
        var separator = false
        for index in (input.startIndex + 1)..<input.endIndex {
            try check()
            let byte = input[index]
            if byte == 40 || byte == 123 && input[index - 1] == 36,
                let end = closing(for: byte)
            {
                guard expected.count < 4096 else {
                    throw NateError.message("Makefile 条件参数超过 4096 层。")
                }
                expected.append(end)
            }
            else if byte == expected.last {
                expected.removeLast()
                if expected.isEmpty {
                    return separator && trim(input[(index + 1)...]).isEmpty
                }
            }
            else if byte == 44, expected.count == 1 {
                separator = true
            }
        }
        return false
    }

    /// 业务作用：只有声明完整变量及可选赋值符的 define 才开启多行值，其它原文按普通行处理。
    /// 参数说明:
    /// - input: define 之后完整的原始声明部分。
    /// - check: 本次输入共用的继续资格。
    /// 返回：变量名完整且末尾省略或只保留合法赋值符时为真。
    private static func definesVariable(_ input: ArraySlice<UInt8>, check: () throws -> Void) throws -> Bool {
        for suffix in [":::=", "::=", ":=", "+=", "?=", "!=", "="] {
            let count = suffix.utf8.count
            if input.count >= count, input.suffix(count).elementsEqual(suffix.utf8) {
                return try variableName(trim(input.dropLast(count)), check: check)
            }
        }
        return try variableName(input, check: check)
    }

    /// 业务作用：变量名及其未求值引用保持原样，普通赋值、目标分隔符和多个名称不能伪造条件。
    /// 参数说明:
    /// - input: 一个已去掉外侧空白的变量名候选。
    /// - check: 完整输入共用的继续资格。
    /// 返回：存在单个完整原名称或未求值引用时为真。
    private static func variableName(_ input: ArraySlice<UInt8>, check: () throws -> Void) throws -> Bool {
        guard !input.isEmpty else {
            return false
        }
        var expected: [UInt8] = []
        for index in input.indices {
            try check()
            let byte = input[index]
            if let closer = closing(for: byte),
                (index > input.startIndex && input[index - 1] == 36 || expected.last == closer)
            {
                guard expected.count < 4096 else {
                    throw NateError.message("Makefile 条件变量名超过 4096 层。")
                }
                expected.append(closer)
            }
            else if byte == expected.last {
                expected.removeLast()
            }
            else if expected.isEmpty && (blank(byte) || [0, 35, 40, 41, 58, 61, 123, 125].contains(byte)) {
                return false
            }
        }
        return expected.isEmpty
    }

    /// 业务作用：指令边界只接受完整小写词，形似关键字的长标识符仍保留正文身份。
    /// 参数说明:
    /// - input: 当前尚未消费、已去除前导空白的原字节。
    /// 返回：取得完整 ASCII 指令词后移动到参数，否则保留当前范围。
    private static func word(from input: inout ArraySlice<UInt8>) -> String? {
        let length = input.prefix {
            (97...122).contains($0)
        }.count
        guard (1...10).contains(length), input.count == length || blank(input[input.startIndex + length])
        else {
            return nil
        }
        let value = String(decoding: input.prefix(length), as: UTF8.self)
        input = trim(input.dropFirst(length))
        return value
    }

    /// 业务作用：忽略指令外侧水平空白而保留其中真实字节。
    /// 参数说明:
    /// - bytes: 原始逻辑范围。
    /// 返回：去掉两端空白的原范围。
    static func trim(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let first = bytes.drop(while: blank)
        guard let end = first.lastIndex(where: { !blank($0) }) else {
            return first
        }
        return first[...end]
    }

    /// 业务作用：区分真正的 Make 水平间隔与值内的其它字节。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：空格或水平 Tab 时为真。
    private static func blank(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9
    }

    /// 业务作用：变量引用只对实际圆括号或花括号选择同类闭合符。
    /// 参数说明:
    /// - byte: 当前已确认的引用开端字节。
    /// 返回：该开端对应的闭合符，其它字节为空。
    private static func closing(for byte: UInt8) -> UInt8? {
        switch byte {
        case 40: 41
        case 123: 125
        default: nil
        }
    }
}
