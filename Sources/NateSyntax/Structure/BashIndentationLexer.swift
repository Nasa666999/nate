import Foundation
import NateCore

struct BashIndentationToken {
    enum Kind: Equatable {
        case word(String?)
        case separator
        case openGroup
        case closeGroup
        case emptyGroup
        case caseEnd
        case redirection
    }

    let kind: Kind
    let lower: Int
    let upper: Int
    let opaque: Bool
}

struct BashIndentationRow {
    let tokens: [BashIndentationToken]
    let continues: Bool
    let startsInLiteral: Bool
    let holdsLiteral: Bool
    let hereDocument: Bool
}

struct BashIndentationLexer {
    private enum Context: Equatable {
        case single
        case double
        case backtick
        case expansion(UInt8)
    }

    private struct HereDocument {
        let word: [UInt8]
        let removesTabs: Bool
    }

    private var contexts: [Context] = []
    private var substitutionCases: [Int: Int] = [:]
    private var carriesWord = false
    private var expectingHereDocument: Bool?
    private var waitingHereDocuments: [HereDocument] = []
    private var substitutionHereDocuments: [HereDocument] = []
    private var activeHereDocuments: ArraySlice<HereDocument> = []
    private var unknownHereDocument = false

    /// 业务作用：按真实物理行传播引号、替换、续行和 here-document 边界，供结构缩进读取裸命令。
    /// 参数说明:
    /// - bytes: 一行不含换行符的原始 UTF-8。
    /// - check: 所有目标共享的取消与截止校验。
    /// 返回：当前行有资格使用的词与操作符；文件正文、字面、来源容量不足不会推测结构。
    mutating func consume(_ bytes: [UInt8], check: () throws -> Void) throws -> BashIndentationRow {
        if unknownHereDocument {
            return BashIndentationRow(
                tokens: [],
                continues: false,
                startsInLiteral: true,
                holdsLiteral: true,
                hereDocument: true
            )
        }
        if let here = activeHereDocuments.first {
            // here-document 吞掉完整物理行。分隔符只结束所属正文，不能在同一行恢复代码解释。
            let body = here.removesTabs ? bytes.drop(while: { $0 == 9 }) : bytes[...]
            if body.elementsEqual(here.word) {
                activeHereDocuments.removeFirst()
                if activeHereDocuments.isEmpty, contexts.isEmpty, !waitingHereDocuments.isEmpty {
                    activeHereDocuments = waitingHereDocuments[...]
                    waitingHereDocuments = []
                }
            }
            return BashIndentationRow(
                tokens: [],
                continues: !contexts.isEmpty,
                startsInLiteral: true,
                holdsLiteral: true,
                hereDocument: true
            )
        }
        var tokens: [BashIndentationToken] = []
        var cursor = 0
        var start: Int? = carriesWord ? 0 : nil
        var opaque = carriesWord
        let startsInLiteral = !contexts.isEmpty
        var continued = false
        var nextCheck = 0
        while cursor < bytes.count {
            if cursor >= nextCheck {
                try check()
                nextCheck = cursor + 256
            }
            let byte = bytes[cursor]
            if substitutionCases[contexts.count] != nil, byte == 35,
                cursor == 0 || [9, 32, 38, 40, 59, 124].contains(bytes[cursor - 1])
            {
                // 命令替换里的注释可以包含闭合括号，必须等到后续真实定界再退出替换。
                cursor = bytes.count
                break
            }
            if contexts.isEmpty {
                if byte == 35 && start == nil {
                    break
                }
                if start == nil, byte == 40, cursor + 1 < bytes.count, bytes[cursor + 1] == 40 {
                    // 算术命令中的 << 是移位运算符。两层原括号均闭合前不解释重定向。
                    start = cursor
                    opaque = true
                    try push(.expansion(41))
                    try push(.expansion(41))
                    cursor += 2
                    continue
                }
                let whitespace = byte == 9 || byte == 32
                if whitespace || Self.isOperator(byte) {
                    if let lower = start {
                        try finishWord(bytes, lower: lower, upper: cursor, opaque: opaque, tokens: &tokens)
                        start = nil
                        opaque = false
                    }
                    if whitespace {
                        cursor += 1
                    }
                    else {
                        try consumeOperator(bytes, cursor: &cursor, tokens: &tokens)
                    }
                    continue
                }
            }
            if byte == 92, start == nil, cursor + 1 == bytes.count {
                continued = true
                break
            }
            if start == nil {
                start = cursor
            }
            if byte == 92, contexts.last != .single {
                opaque = true
                if cursor + 1 == bytes.count {
                    continued = true
                    cursor += 1
                }
                else {
                    cursor += 2
                }
                continue
            }
            if try consumeContext(bytes, cursor: &cursor) {
                opaque = true
                continue
            }
            cursor += 1
        }
        let holdsLiteral = !contexts.isEmpty
        if let lower = start {
            if holdsLiteral || continued {
                if expectingHereDocument != nil {
                    // 分隔符尚无完整原字节证据，后续内容不能被当成脚本块。
                    unknownHereDocument = true
                }
                tokens.append(
                    BashIndentationToken(kind: .word(nil), lower: lower, upper: cursor, opaque: true)
                )
            }
            else {
                try finishWord(bytes, lower: lower, upper: cursor, opaque: opaque, tokens: &tokens)
            }
        }
        carriesWord = holdsLiteral || continued && start != nil
        let continues = holdsLiteral || continued
        if !continued && !substitutionHereDocuments.isEmpty {
            // 替换仍持续时先消费其专属 here-document，外层尚未取得行结束语义。
            activeHereDocuments = substitutionHereDocuments[...]
            substitutionHereDocuments = []
        }
        else if !continues && !waitingHereDocuments.isEmpty {
            activeHereDocuments = waitingHereDocuments[...]
            waitingHereDocuments = []
        }
        if !continues {
            expectingHereDocument = nil
        }
        return BashIndentationRow(
            tokens: tokens,
            continues: continues,
            startsInLiteral: startsInLiteral,
            holdsLiteral: holdsLiteral,
            hereDocument: false
        )
    }

    /// 业务作用：明确区分 Shell 词边界上的控制操作符与普通词内容。
    /// 参数说明:
    /// - byte: 当前不在引号中的原始字节。
    /// 返回：字节是原生命令分隔、重定向或分组入口时为真。
    private static func isOperator(_ byte: UInt8) -> Bool {
        switch byte {
        case 38, 40, 41, 59, 60, 62, 124:
            return true
        default:
            return false
        }
    }

    /// 业务作用：读取有明确边界的 Shell 控制操作符，here-string 不登记 here-document。
    /// 参数说明:
    /// - bytes: 当前行原字节。
    /// - cursor: 读入起点，成功后推进到操作符末尾。
    /// - tokens: 本行控制词结果。
    /// 返回：完成操作符分类，只有真实重定向可登记后继分隔符。
    private mutating func consumeOperator(
        _ bytes: [UInt8],
        cursor: inout Int,
        tokens: inout [BashIndentationToken]
    ) throws {
        let lower = cursor
        let remainder = bytes[lower...]
        let kind: BashIndentationToken.Kind
        if remainder.starts(with: [59, 59, 38]) {
            kind = .caseEnd
            cursor += 3
        }
        else if remainder.starts(with: [59, 59]) || remainder.starts(with: [59, 38]) {
            kind = .caseEnd
            cursor += 2
        }
        else if remainder.starts(with: [60, 60, 60]) {
            kind = .redirection
            cursor += 3
        }
        else if remainder.starts(with: [60, 60]) {
            let stripsTabs = remainder.starts(with: [60, 60, 45])
            if expectingHereDocument != nil {
                unknownHereDocument = true
            }
            expectingHereDocument = stripsTabs
            kind = .redirection
            cursor += stripsTabs ? 3 : 2
        }
        else if bytes[lower] == 40 {
            let following = remainder.dropFirst().drop(while: { $0 == 9 || $0 == 32 })
            if following.first == 41 {
                kind = .emptyGroup
                cursor = following.startIndex + 1
            }
            else {
                kind = .openGroup
                cursor += 1
            }
        }
        else {
            switch bytes[lower] {
            case 41:
                kind = .closeGroup
            case 60, 62:
                kind = .redirection
            default:
                kind = .separator
            }
            cursor += 1
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("Bash 结构换行的单行词元超过 65536 项。")
        }
        tokens.append(BashIndentationToken(kind: kind, lower: lower, upper: cursor, opaque: false))
    }

    /// 业务作用：将完整词提交为保留字候选，或登记显式 here-document 分隔符。
    /// 参数说明:
    /// - bytes: 当前行原字节。
    /// - lower: 词的原起点。
    /// - upper: 词的原终点。
    /// - opaque: 是否包含引用、替换或转义。
    /// - tokens: 本行控制词结果。
    /// 返回：只有未引用的完整词能参与命令语法，分隔符不会同时参与结构判断。
    private mutating func finishWord(
        _ bytes: [UInt8],
        lower: Int,
        upper: Int,
        opaque: Bool,
        tokens: inout [BashIndentationToken]
    ) throws {
        guard tokens.count < 65_536 else {
            throw NateError.message("Bash 结构换行的单行词元超过 65536 项。")
        }
        let source = bytes[lower..<upper]
        if let stripsTabs = expectingHereDocument {
            expectingHereDocument = nil
            if let word = Self.delimiter(source), waitingHereDocuments.count < 256 {
                waitingHereDocuments.append(HereDocument(word: word, removesTabs: stripsTabs))
            }
            else {
                unknownHereDocument = true
            }
            tokens.append(BashIndentationToken(kind: .word(nil), lower: lower, upper: upper, opaque: true))
            return
        }
        let word = !opaque && source.count <= 8 ? String(decoding: source, as: UTF8.self) : nil
        tokens.append(BashIndentationToken(kind: .word(word), lower: lower, upper: upper, opaque: opaque))
    }

    /// 业务作用：解释常规 here-document 分隔符的引号移除，保持其余字节原样。
    /// 参数说明:
    /// - source: 原重定向之后一个完整词的字节。
    /// 返回：允许精确比对的分隔符；超量或特殊引用语义返回空，后继行保持字面。
    private static func delimiter(_ source: ArraySlice<UInt8>) -> [UInt8]? {
        guard source.count <= 4096 else {
            return nil
        }
        var quote: UInt8?
        var output: [UInt8] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let byte = source[cursor]
            if quote == byte {
                quote = nil
            }
            else if byte == 36, cursor + 1 < source.endIndex,
                [39, 34, 40, 123, 91].contains(source[cursor + 1])
            {
                return nil
            }
            else if quote == nil && (byte == 34 || byte == 39) {
                quote = byte
            }
            else if byte == 92, quote != 39, cursor + 1 < source.endIndex,
                quote == nil || [34, 36, 92, 96].contains(source[cursor + 1])
            {
                cursor += 1
                output.append(source[cursor])
            }
            else {
                output.append(byte)
            }
            cursor += 1
        }
        return quote == nil ? output : nil
    }

    /// 业务作用：传播引号与参数、算术或命令替换的真实边界，内部标点不给外层语法授权。
    /// 参数说明:
    /// - bytes: 当前行原字节。
    /// - cursor: 正在识别的原字节位置，消费定界内容时向前推进。
    /// 返回：匹配了真实定界或处于不透明上下文时为真。
    private mutating func consumeContext(_ bytes: [UInt8], cursor: inout Int) throws -> Bool {
        let byte = bytes[cursor]
        switch contexts.last {
        case .single:
            if byte == 39 {
                contexts.removeLast()
            }
            cursor += 1
            return true
        case .backtick:
            if byte == 96 {
                contexts.removeLast()
            }
            cursor += 1
            return true
        case .double:
            if byte == 34 {
                contexts.removeLast()
                cursor += 1
                return true
            }
        case .expansion(let closing):
            let depth = contexts.count
            if let cases = substitutionCases[depth] {
                if byte == 40, cursor + 1 < bytes.count, bytes[cursor + 1] == 40 {
                    // 替换中的算术命令使用算术括号，移位运算符不登记 here-document。
                    try push(.expansion(41))
                    try push(.expansion(41))
                    cursor += 2
                    return true
                }
                if byte == 60, bytes[cursor...].starts(with: [60, 60]) {
                    if bytes[cursor...].starts(with: [60, 60, 60]) {
                        cursor += 3
                    }
                    else {
                        consumeSubstitutionHereDocument(bytes, cursor: &cursor)
                    }
                    return true
                }
                // case 分支的 ) 不关闭外层命令替换，只有同一替换中的 esac 能恢复关闭资格。
                if byte == 99, Self.substitutionWord([99, 97, 115, 101], in: bytes, at: cursor) {
                    guard cases < 256 else {
                        throw NateError.message("Bash 命令替换的 case 嵌套超过 256 层。")
                    }
                    substitutionCases[depth] = cases + 1
                    cursor += 4
                    return true
                }
                if byte == 101, cases > 0, Self.substitutionWord([101, 115, 97, 99], in: bytes, at: cursor) {
                    substitutionCases[depth] = cases - 1
                    cursor += 4
                    return true
                }
                if byte == closing, cases > 0 {
                    cursor += 1
                    return true
                }
            }
            if byte == closing {
                contexts.removeLast()
                substitutionCases.removeValue(forKey: depth)
                cursor += 1
                return true
            }
            let opener: UInt8 = closing == 41 ? 40 : (closing == 93 ? 91 : 123)
            if byte == opener {
                try push(.expansion(closing))
                if substitutionCases[depth] != nil {
                    substitutionCases[contexts.count] = 0
                }
                cursor += 1
                return true
            }
        case nil:
            break
        }
        if byte == 36, cursor + 1 < bytes.count {
            switch bytes[cursor + 1] {
            case 40:
                try push(.expansion(41))
                if cursor + 2 == bytes.count || bytes[cursor + 2] != 40 {
                    substitutionCases[contexts.count] = 0
                }
            case 91:
                try push(.expansion(93))
            case 123:
                try push(.expansion(125))
            default:
                break
            }
            if [40, 91, 123].contains(bytes[cursor + 1]) {
                cursor += 2
                return true
            }
        }
        if byte == 96 {
            try push(.backtick)
        }
        else if byte == 39, contexts.last != .double {
            try push(.single)
        }
        else if byte == 34 {
            try push(.double)
        }
        else if contexts.isEmpty {
            return false
        }
        cursor += 1
        return true
    }

    /// 业务作用：登记命令替换自己的 here-document，正文中的右括号不关闭外层替换。
    /// 参数说明:
    /// - bytes: 当前物理行原字节。
    /// - cursor: 双小于号的起点，成功时移动到分隔符之后。
    /// 返回：完整登记分隔符；无法取得可靠证据时后继行按原缩进处理。
    private mutating func consumeSubstitutionHereDocument(_ bytes: [UInt8], cursor: inout Int) {
        let stripsTabs = bytes[cursor...].starts(with: [60, 60, 45])
        cursor += stripsTabs ? 3 : 2
        while cursor < bytes.count && (bytes[cursor] == 9 || bytes[cursor] == 32) {
            cursor += 1
        }
        let start = cursor
        var quote: UInt8?
        while cursor < bytes.count && cursor - start <= 4096 {
            let byte = bytes[cursor]
            if quote == byte {
                quote = nil
            }
            else if quote == nil && (byte == 34 || byte == 39) {
                quote = byte
            }
            else if byte == 92 && quote != 39 && cursor + 1 < bytes.count {
                cursor += 1
            }
            else if quote == nil && (byte == 9 || byte == 32 || Self.isOperator(byte)) {
                break
            }
            cursor += 1
        }
        guard cursor > start, quote == nil,
            let word = Self.delimiter(bytes[start..<cursor]), substitutionHereDocuments.count < 256
        else {
            unknownHereDocument = true
            return
        }
        substitutionHereDocuments.append(HereDocument(word: word, removesTabs: stripsTabs))
    }

    /// 业务作用：只从命令替换中的裸命令起始识别 case 或 esac，不把实参相同拼写作为块边界。
    /// 参数说明:
    /// - spelling: 原样匹配的 ASCII 保留字。
    /// - bytes: 原物理行字节。
    /// - cursor: 候选保留字起点。
    /// 返回：当前词的两侧都具备命令位置证据时为真。
    private static func substitutionWord(_ spelling: [UInt8], in bytes: [UInt8], at cursor: Int) -> Bool {
        let end = cursor + spelling.count
        guard bytes[cursor...].starts(with: spelling),
            end == bytes.count || bytes[end] == 9 || bytes[end] == 32 || isOperator(bytes[end])
        else {
            return false
        }
        if cursor == 0 {
            return true
        }
        let previous = bytes[cursor - 1]
        let startsCase = spelling.first == 99
        if [38, 40, 59, 124].contains(previous) || startsCase && previous == 41 {
            return true
        }
        guard previous == 9 || previous == 32 else {
            return false
        }
        var start = cursor - 1
        while start > 0 && (bytes[start - 1] == 9 || bytes[start - 1] == 32) {
            start -= 1
        }
        if start == 0 {
            return true
        }
        if [38, 40, 59, 124].contains(bytes[start - 1]) || startsCase && bytes[start - 1] == 41 {
            return true
        }
        // 同一命令的 then、do 或 else 之后可直接开始复合命令。完整裸词才可承担这个角色。
        let wordEnd = start
        while start > 0, wordEnd - start < 5, (97...122).contains(bytes[start - 1]) {
            start -= 1
        }
        guard start == 0 || bytes[start - 1] == 9 || bytes[start - 1] == 32 || isOperator(bytes[start - 1])
        else {
            return false
        }
        return ["then", "do", "else"].contains(String(decoding: bytes[start..<wordEnd], as: UTF8.self))
    }

    /// 业务作用：限制为结构缩进保留的嵌套引用与替换上下文。
    /// 参数说明:
    /// - context: 已获得真实开启字节证据的上下文。
    /// 返回：仍有容量时进入；超出 256 层后拒绝本次整批结构准备。
    private mutating func push(_ context: Context) throws {
        guard contexts.count < 256 else {
            throw NateError.message("Bash 结构换行的引用和替换嵌套超过 256 层。")
        }
        contexts.append(context)
    }
}
