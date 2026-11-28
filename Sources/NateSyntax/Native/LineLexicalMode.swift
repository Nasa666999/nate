import Foundation

enum LineLexicalMode: String, Sendable {
    case properties = "props"
    case diff
    case makefile = "make"
    case ihex
    case srec
    case tehex
    case tex
    case spice

    /// 业务作用：每个逐行模式只在完整的自身样式资源存在时参与呈现。
    /// 参数说明: 无。
    /// 返回：当前模式必须具备的固定样式编号。
    var requiredStyles: [Int] {
        switch self {
        case .properties: return Array(0...5)
        case .diff: return Array(0...6)
        case .makefile: return Array(0...5) + [9]
        case .ihex:
            return Array(0...18).filter {
                $0 != 8
            }
        case .srec:
            return Array(0...18).filter {
                $0 != 11
            }
        case .tehex: return [0, 1, 2, 3, 4, 5, 7, 9, 10, 12, 13, 16, 17, 18]
        case .tex: return Array(0...5)
        case .spice: return Array(0...8)
        }
    }

    /// 业务作用：每个词法身份保留基础呈现类别，不让相同颜色合并不同作用域。
    /// 参数说明: 无。
    /// 返回：按当前模式原始编号排列的基础类别。
    var kinds: [SyntaxKind] {
        switch self {
        case .properties:
            return [.text, .comment, .heading, .punctuation, .keyword, .keyword]
        case .diff:
            return [
                .text, .comment, .keyword, .heading, .number, .text, .text, .text, .text, .text, .text, .text,
            ]
        case .makefile:
            return [.text, .comment, .keyword, .keyword, .punctuation, .heading, .text, .text, .text, .text]
        case .tex:
            return [.comment, .punctuation, .punctuation, .punctuation, .keyword, .text]
        case .spice:
            return [.text, .text, .keyword, .keyword, .keyword, .number, .punctuation, .text, .comment]
        case .ihex, .srec, .tehex:
            return [
                .text, .punctuation, .keyword, .keyword, .number, .number, .number, .number,
                .number, .number, .number, .number, .text, .text, .text, .text, .number,
                .number, .text,
            ]
        }
    }
}
