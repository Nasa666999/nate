import NateCore

struct PythonIndentationOrigin {
    let range: ByteRange
    let column: Int
}

private enum PythonIndentationClause: String {
    case condition = "if", elif, whileLoop = "while", loop = "for", withClause = "with"
    case otherwise = "else", attempt = "try", except, final = "finally"
    case function = "def", type = "class", match, matchCase = "case"
}

private struct PythonMatchIndentation {
    let opening: Int
    var branch: Int?
}

struct PythonIndentationState {
    private var logicalOrigin: PythonIndentationOrigin?
    private var clause: PythonIndentationClause?
    private var awaitingAsync = false
    private var payload = false
    private var loopHasIn = false
    private var namedDefinition = false
    private var functionParameters = false
    private var exceptStar = false
    private var lambdas = 0
    private var delimiters: [UInt8] = []
    private var matches: [PythonMatchIndentation] = []
    private(set) var completed: ByteRange?

    /// 业务作用：`match` 的分支必须在后续逻辑行开始，带同行类型正文的软关键字名称不建立块。
    /// 参数说明: 无。
    /// 返回：当前完整头是模式开端时为真；其它复合语句允许在冒号后拆分同行正文。
    var requiresLineBoundary: Bool {
        clause == .match && completed != nil
    }

    /// 业务作用：按逻辑行的第一个词确定复合语句资格，区分 `async`、`for … in` 和头部尚未闭合的 lambda。
    /// 参数说明:
    /// - word: 词法已确定的短原始名称，长名称的空摘要仍表示一个真实标识符。
    /// - softKeywordSeparated: 软关键字与后继表达式存在原始边界时为真。
    /// - origin: 当前物理行的原空白及语法列。
    /// 返回：记录名称和已确认的头部证据；普通语句不授予块缩进资格。
    mutating func word(_ word: String, softKeywordSeparated: Bool, origin: PythonIndentationOrigin) {
        if logicalOrigin == nil {
            begin(origin)
            awaitingAsync = word == "async"
            if !awaitingAsync, let candidate = PythonIndentationClause(rawValue: word) {
                if candidate == .match || candidate == .matchCase {
                    guard softKeywordSeparated else {
                        return
                    }
                    if candidate == .matchCase {
                        guard let match = matches.last, match.opening < origin.column,
                            match.branch == nil || match.branch == origin.column
                        else {
                            return
                        }
                    }
                }
                clause = candidate
            }
            return
        }
        if awaitingAsync {
            awaitingAsync = false
            if let continued = PythonIndentationClause(rawValue: word),
                continued == .function || continued == .loop || continued == .withClause
            {
                clause = continued
            }
            return
        }
        guard activeHeader() else {
            return
        }
        if delimiters.isEmpty {
            if clause == .loop, !loopHasIn, payload, word == "in" {
                loopHasIn = true
                payload = false
                return
            }
            if word == "lambda" {
                lambdas += 1
            }
            if (clause == .function || clause == .type) && !payload {
                namedDefinition = PythonIndentationClause(rawValue: word) == nil && word != "async"
            }
        }
        payload = true
    }

    /// 业务作用：顺序跟踪代码分隔符，字典、切片、括号、字面与头部内层冒号不建立外层代码块。
    /// 参数说明:
    /// - byte: 当前物理行已遮蔽字面后的实际字节。
    /// - origin: 当前物理行的原空白及语法列。
    /// 返回：更新逻辑行的结构证据；过量嵌套抛错，交叉闭合撤销未完成头部资格。
    mutating func byte(_ byte: UInt8, origin: PythonIndentationOrigin) throws {
        guard byte != 9, byte != 12, byte != 32 else {
            return
        }
        if logicalOrigin == nil {
            begin(origin)
        }
        awaitingAsync = false
        let active = activeHeader()
        if byte == 58, delimiters.isEmpty {
            if active {
                if lambdas > 0 {
                    lambdas -= 1
                }
                else {
                    completeHeader()
                }
            }
            return
        }
        if byte == 40 || byte == 91 || byte == 123 {
            guard delimiters.count < 65_536 else {
                throw NateError.message("Python 语言缩进的括号嵌套超过 65536 层。")
            }
            if delimiters.isEmpty, clause == .function, namedDefinition, byte == 40 {
                functionParameters = true
            }
            delimiters.append(byte == 40 ? 41 : (byte == 91 ? 93 : 125))
        }
        else if byte == 41 || byte == 93 || byte == 125 {
            if delimiters.last == byte {
                delimiters.removeLast()
            }
            else {
                // 交叉括号不能把内层冒号升级为复合语句，原逻辑行的头部保持无效。
                clause = nil
                delimiters.removeAll(keepingCapacity: true)
            }
        }
        if active {
            if byte == 0 || byte == 59
                || !payload && (clause == .match || clause == .matchCase) && [46, 61].contains(byte)
            {
                clause = nil
            }
            else if clause == .except, byte == 42, !payload && !exceptStar {
                exceptStar = true
            }
            else {
                payload = true
            }
        }
    }

    /// 业务作用：完整的 `match` 头建立真实分支层级，逻辑续行保持原语句和所属开端。
    /// 参数说明:
    /// - continuing: 实际反斜线或 Python 字面仍跨越此物理行时为真。
    /// 返回：逻辑行完整时关闭语句，未完结时保留来源；过量模式层级抛错。
    mutating func endLine(continuing: Bool) throws {
        guard delimiters.isEmpty, !continuing else {
            return
        }
        if clause == .match, completed != nil, let logicalOrigin {
            guard matches.count < 65_536 else {
                throw NateError.message("Python 语言缩进的模式层级超过 65536 层。")
            }
            matches.append(PythonMatchIndentation(opening: logicalOrigin.column, branch: nil))
        }
        logicalOrigin = nil
        clause = nil
        awaitingAsync = false
        payload = false
        loopHasIn = false
        namedDefinition = false
        functionParameters = false
        exceptStar = false
        lambdas = 0
        completed = nil
    }

    /// 业务作用：新语句以真实缩进确定仍适用的模式范围，空行与注释没有权力结束分支。
    /// 参数说明:
    /// - origin: 第一个真实代码词所在物理行的原前缀及语法列。
    /// 返回：当前逻辑语句固定其开端，已经退出的外层范围停止为 `case` 提供证据。
    private mutating func begin(_ origin: PythonIndentationOrigin) {
        while let match = matches.last, match.opening >= origin.column {
            matches.removeLast()
        }
        logicalOrigin = origin
    }

    /// 业务作用：真正的同行正文结束头部缩进资格，后续字面或冒号不能重新启用原头部。
    /// 参数说明: 无。
    /// 返回：仍在已辨认的头部为真；遇到同行正文后清除已完成标记。
    private mutating func activeHeader() -> Bool {
        if completed != nil {
            completed = nil
            clause = nil
        }
        return clause != nil
    }

    /// 业务作用：复合语句冒号只在该语句必需的头部形态齐备时建立块缩进证据。
    /// 参数说明: 无。
    /// 返回：记录原开端缩进，并固定首个 `case` 分支的实际列；不完整头部保持无效。
    private mutating func completeHeader() {
        guard let clause, let logicalOrigin else {
            return
        }
        let valid: Bool
        switch clause {
        case .otherwise, .attempt, .final: valid = !payload
        case .function: valid = namedDefinition && functionParameters
        case .type: valid = namedDefinition
        case .loop: valid = loopHasIn && payload
        case .except: valid = !exceptStar || payload
        default: valid = payload
        }
        guard valid else {
            self.clause = nil
            return
        }
        completed = logicalOrigin.range
        if clause == .matchCase, let index = matches.indices.last, matches[index].branch == nil {
            matches[index].branch = logicalOrigin.column
        }
    }

    /// 业务作用：词边界保留 ASCII 关键字的完整名称，带 Unicode 后缀的标识符不会借用关键字资格。
    /// 参数说明:
    /// - byte: 已固定的源 UTF-8 字节。
    /// 返回：可能开始标识符时为真，已遮蔽的字面和数字保持独立。
    static func isWordStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }

    /// 业务作用：在有界的逻辑行扫描中同时保护关键字的数值与 Unicode 后缀。
    /// 参数说明:
    /// - byte: 当前可能紧跟现有标识符的原字节。
    /// 返回：该字节属于同一可能名称时为真。
    static func isWordPart(_ byte: UInt8) -> Bool {
        isWordStart(byte) || (48...57).contains(byte)
    }
}
