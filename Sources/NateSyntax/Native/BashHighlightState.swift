import Foundation
import NateCore

enum BashHighlightStyle: UInt8, Sendable {
    case plain = 0
    case error = 1
    case comment = 2
    case number = 3
    case keyword = 4
    case string = 5
    case literal = 6
    case punctuation = 7
    case identifier = 8
    case scalar = 9
    case parameter = 10
    case command = 11
    case hereDelimiter = 12
    case hereText = 13
}

enum BashHighlightCommand: Sendable, Equatable {
    case start
    case arguments
    case iterator
    case test
    case singleBracket
    case doubleBracket
    case arithmetic
}

enum BashHighlightQuote: Sendable, Equatable {
    case literal
    case escapedLiteral
    case string
    case backticks
    case command
    case parameter

    var style: BashHighlightStyle {
        switch self {
        case .literal: .literal
        case .escapedLiteral, .string: .string
        case .backticks, .command: .command
        case .parameter: .parameter
        }
    }
}

struct BashHighlightDocument: Sendable, Equatable {
    let delimiter: [UInt8]
    let stripsTabs: Bool
}

struct BashHighlightState: Sendable, Equatable {
    var command: BashHighlightCommand = .start
    var quotes: [BashHighlightQuote] = []
    var here: BashHighlightDocument?
    var continued = false
    var arithmeticDepth = 0
    var arithmeticCloser: UInt8 = 41

    /// 业务作用：限制引用和替换堆栈，未完成的嵌套不会获得后续行的部分呈现。
    /// 参数说明:
    /// - quote: 当前真实打开的引用或变量替换。
    /// 返回：仍有完整嵌套容量时登记，否则拒绝本次样式准备。
    mutating func push(_ quote: BashHighlightQuote) throws {
        guard quotes.count < 256 else {
            throw NateError.message("Bash 高亮的引用和替换嵌套超过 256 层。")
        }
        quotes.append(quote)
    }
}
