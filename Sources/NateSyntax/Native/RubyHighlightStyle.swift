enum RubyHighlightStyle: UInt8, CaseIterable, Sendable {
    case whitespace = 0
    case error, lineComment, documentation, number, keyword, string, character
    case className, methodName, operation, identifier, regex, global, symbol, moduleName
    case instance, classVariable, command, data, heredocDelimiter, heredocLiteral
    case heredocString, heredocCommand, percentLiteral, percentString, percentCommand, percentRegex
    case interpolatedWords, demotedKeyword, standardInput, standardOutput
    case standardError = 40
    case wordList, symbolList, interpolatedSymbols, percentSymbol

    /// 业务作用：保持原生数字类别，并为主题继承和结构词法提供对应的通用类别。
    /// 参数说明: 无。
    /// 返回：代码、注释、字面及数据互不借用结构权限。
    var kind: SyntaxKind {
        switch self {
        case .lineComment, .documentation:
            return .comment
        case .data, .string, .character, .regex, .symbol, .command, .heredocDelimiter, .heredocLiteral,
            .heredocString, .heredocCommand, .percentLiteral, .percentString, .percentCommand,
            .percentRegex, .wordList, .interpolatedWords, .interpolatedSymbols, .symbolList, .percentSymbol:
            return .string
        case .number:
            return .number
        case .keyword:
            return .keyword
        case .demotedKeyword:
            return .keyword
        case .operation:
            return .punctuation
        default:
            return .text
        }
    }

    /// 业务作用：用已确认的原字节开端区分引号、正则及八种带类型的百分号字面。
    /// 参数说明:
    /// - bytes: 同一物理行内已经确认的字面开端。
    /// 返回：当前完整字面的实际数字样式，内部代码标点不参与外层结构。
    static func literal(_ bytes: ArraySlice<UInt8>) -> Self {
        switch bytes.first {
        case 39:
            return .character
        case 96:
            return .command
        case 47:
            return .regex
        case 37:
            switch bytes.dropFirst().first {
            case 113: return .percentLiteral
            case 120: return .percentCommand
            case 114: return .percentRegex
            case 119: return .wordList
            case 87: return .interpolatedWords
            case 73: return .interpolatedSymbols
            case 105: return .symbolList
            case 115: return .percentSymbol
            default: return .percentString
            }
        default:
            return .string
        }
    }
}
