import Foundation
import NateCore

enum PythonKeywordContext: Sendable, Equatable {
    case other, className, functionName, importName, cdef, cpdef

    var isCython: Bool {
        self == .cdef || self == .cpdef
    }
}

enum PythonIdentifiers {
    /// 业务作用：在合法 UTF-8 边界上识别 Python 标识符，不把 emoji、连接符或孤立组合符当成名称首位。
    /// 参数说明:
    /// - bytes: 当前完整行的有效 UTF-8 字节。
    /// - offset: 当前码点的起始边界。
    /// - first: 是否正在识别名称首位。
    /// - rules: 固定语言资源提供的 Unicode 范围。
    /// 返回：合法名称码点的字节宽度，不属于名称时为零。
    static func width(_ bytes: [UInt8], at offset: Int, first: Bool, rules: UnicodeIdentifierRules) -> Int {
        guard offset < bytes.count else {
            return 0
        }
        let byte = bytes[offset]
        if byte < 128 {
            return (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
                || (!first && (48...57).contains(byte)) ? 1 : 0
        }
        let count = byte < 0xe0 ? 2 : (byte < 0xf0 ? 3 : 4)
        guard byte >= 0xc2, offset + count <= bytes.count else {
            return 0
        }
        var scalar = UInt32(byte & (count == 2 ? 0x1f : (count == 3 ? 0x0f : 0x07)))
        for index in (offset + 1)..<(offset + count) {
            scalar = scalar << 6 | UInt32(bytes[index] & 0x3f)
        }
        return rules.contains(scalar, first: first) ? count : 0
    }

    /// 业务作用：区分定义名称、保留字、内置名称与属性，分类只依赖固定正文和当前词法上下文。
    /// 参数说明:
    /// - bytes: 当前完整行。
    /// - range: 已识别标识符的行内范围。
    /// - keywords: 精确保留字集合。
    /// - secondary: 独立内置标识符集合。
    /// - attribute: 前置点号的属性类别，为空时没有属性证据。
    /// - context: 上一个有语法作用的关键字，完成后推进定义上下文。
    /// 返回：Python 公开样式编号，不修改正文。
    static func style(
        _ bytes: [UInt8],
        range: Range<Int>,
        keywords: Set<String>,
        secondary: Set<String>,
        attribute: Int?,
        context: inout PythonKeywordContext
    ) -> Int {
        let word = String(decoding: bytes[range], as: UTF8.self)
        let style: Int
        if (context == .importName && word == "as")
            || (keywords.contains(word) && !isSoftIdentifier(word, bytes: bytes, range: range))
        {
            style = 5
        }
        else if context == .className {
            style = 8
        }
        else if context == .functionName {
            style = 9
        }
        else if context.isCython {
            let next = nextNonWhitespace(bytes, from: range.upperBound)
            style = next == 40 ? 9 : (next == 58 ? 8 : 11)
        }
        else if secondary.contains(word) {
            style = 14
        }
        else {
            style = attribute ?? 11
        }
        if style == 5 {
            switch word {
            case "class": context = .className
            case "def": context = .functionName
            case "import", "cimport": context = .importName
            case "cdef": context = .cdef
            case "cpdef": context = .cpdef
            default:
                if !context.isCython {
                    context = .other
                }
            }
        }
        else if !context.isCython {
            context = .other
        }
        return style
    }

    /// 业务作用：按当前物理行首位置识别装饰器起点，表达式中的矩阵乘法仍属于运算符。
    /// 参数说明:
    /// - bytes: 当前连续正文片段。
    /// - offset: 候选标记或名称的起点。
    /// 返回：该位置之前仅有本行空格与 Tab 时为真。
    static func firstNonWhitespace(_ bytes: [UInt8], at offset: Int) -> Bool {
        var cursor = offset
        while cursor > 0 {
            let byte = bytes[cursor - 1]
            if byte == 10 || byte == 13 {
                break
            }
            guard byte == 32 || byte == 9 else {
                return false
            }
            cursor -= 1
        }
        return true
    }

    /// 业务作用：保留跨物理行点号的属性证据，注释中的点号不能为后续名称授予属性类别。
    /// 参数说明:
    /// - bytes: 当前行的有效 UTF-8 正文。
    /// - offset: 名称之前或物理行结束边界。
    /// - tokens: 该位置之前已确认的样式。
    /// - base: 当前片段在快照中的起点。
    /// - decoratorLine: 当前物理行首个非空白字符是否为装饰器标记。
    /// - previous: 前一行延续的点号类别。
    /// 返回：普通属性为 20、装饰器属性为 15，没有可信点号时为空。
    static func attributeStyle(
        _ bytes: [UInt8],
        before offset: Int,
        tokens: [SyntaxToken],
        base: Int,
        decoratorLine: Bool,
        previous: Int?
    ) -> Int? {
        var cursor = offset
        while cursor > 0 && [32, 9, 10, 13, 92].contains(bytes[cursor - 1]) {
            cursor -= 1
        }
        guard cursor > 0 else {
            return previous
        }
        let dot = cursor - 1
        guard bytes[dot] == 46 else {
            return nil
        }
        if let token = tokens.last(where: {
            $0.range.lower <= base + dot && $0.range.upper > base + dot
        }),
            token.kind == .comment
        {
            return nil
        }
        return decoratorLine ? 15 : 20
    }

    /// 业务作用：按上下文将 match 和 case 保留为普通名称，避免赋值或属性访问被标为语句。
    /// 参数说明:
    /// - word: 当前完整名称。
    /// - bytes: 当前物理行。
    /// - range: 名称的行内字节范围。
    /// 返回：软关键字当前应作为普通标识符时为真。
    private static func isSoftIdentifier(_ word: String, bytes: [UInt8], range: Range<Int>) -> Bool {
        guard word == "match" || word == "case" else {
            return false
        }
        guard firstNonWhitespace(bytes, at: range.lowerBound) else {
            return true
        }
        var cursor = range.upperBound
        while cursor < bytes.count && [32, 9, 10, 13].contains(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < bytes.count else {
            return false
        }
        if bytes[cursor] == 61 || bytes[cursor] == 35 {
            return true
        }
        if bytes[cursor] == 46 {
            guard let next = nextNonWhitespace(bytes, from: cursor + 1) else {
                return true
            }
            return !(48...57).contains(next)
        }
        return false
    }

    /// 业务作用：为定义名称和软关键字检查后续语法标记，空白不改变当前声明意图。
    /// 参数说明:
    /// - bytes: 当前连续正文片段。
    /// - offset: 当前标识符之后的字节边界。
    /// 返回：片段内首个非空白字节，没有后续证据时为空。
    private static func nextNonWhitespace(_ bytes: [UInt8], from offset: Int) -> UInt8? {
        var cursor = offset
        while cursor < bytes.count && [32, 9, 10, 13].contains(bytes[cursor]) {
            cursor += 1
        }
        return cursor < bytes.count ? bytes[cursor] : nil
    }
}
