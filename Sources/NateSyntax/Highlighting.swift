import Foundation
import NateCore

public enum SyntaxKind: String, Sendable {
    case keyword, string, comment, number, punctuation, heading, tag, text
}

public struct SyntaxToken: Sendable {
    public let range: ByteRange
    public let kind: SyntaxKind
    public let foreground: String?
    public let background: String?
    public let fontStyle: Int
    public let lexicalStyle: String

    /// 业务作用：携带可配置语法呈现，样式不进入正文历史。
    /// 参数说明:
    /// - range: 所属快照字节范围。
    /// - kind: 默认主题分类。
    /// - foreground: 资源显式指定的前景色，为空时继承主题。
    /// - background: 资源显式指定的背景色，为空时继承视图底色。
    /// - fontStyle: UDL 粗体、斜体和下划线位集合。
    /// - lexicalStyle: 原词法样式身份，为空时采用基础类别；颜色相同不代表词法作用域相同。
    /// 返回：独立呈现属性。
    public init(
        range: ByteRange,
        kind: SyntaxKind,
        foreground: String? = nil,
        background: String? = nil,
        fontStyle: Int = 0,
        lexicalStyle: String? = nil
    ) {
        self.range = range
        self.kind = kind
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
        self.lexicalStyle = lexicalStyle ?? kind.rawValue
    }

    /// 业务作用：代码结构只使用真实代码标点，字符串、注释和宏体不能制造主代码块。
    /// 参数说明: 无。
    /// 返回：当前范围不应贡献代码折叠或结构缩进标点时为真。
    public var isStructureOpaque: Bool {
        kind == .string || kind == .comment || lexicalStyle == "c:preprocessor"
    }
}

public struct SyntaxState: Sendable, Equatable {
    public var blockEnd = ""
    public var quote: UInt8?
    public var diagnostic: String?
    var python = PythonLexicalState()
    var json = JSONLexicalState()
    var c = CLexicalState()
    var registry = RegistryLexicalState()

    /// 业务作用：为行间词法传播建立中性状态。
    /// 参数说明: 无。
    /// 返回：未处于跨行注释或字符串的状态。
    public init() {}
}

public struct SyntaxScanner: Sendable {
    let language: LanguageDefinition
    let keywords: Set<String>
    let secondaryKeywords: Set<String>
    let documentationKeywords: Set<String>
    let snapshot: DocumentSnapshot?
    let deadline: ContinuousClock.Instant

    /// 业务作用：一次后台分析固定语言资源并复用关键字集合，逐行传播不重复构建整份资源。
    /// 参数说明:
    /// - language: 本次分析采用的不可变语言定义。
    /// - snapshot: 完整呈现时用于确认后续字面证据；为空时只传播当前片段的状态。
    /// 返回：可跨后台任务传递的扫描上下文，词法状态由每个调用流程分别持有。
    public init(language: LanguageDefinition, snapshot: DocumentSnapshot? = nil) {
        self.language = language
        self.snapshot =
            [
                "python", "escseq", "errorlist", "ini", "props", "diff", "makefile", "registry", "ihex",
                "srec", "tehex", "tex",
            ].contains(
                language.id
            )
            ? snapshot : nil
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        if language.id == "makefile" {
            // Makefile 在行扫描入口有界复验原始词表，提前建立 String 集合会合并名称并重复占用资源。
            keywords = []
            secondaryKeywords = []
            documentationKeywords = []
            return
        }
        keywords = Set(
            ["python", "c", "cpp"].contains(language.id)
                ? language.keywordGroups?["instre1"] ?? language.keywords : language.keywords
        )
        secondaryKeywords = Set(
            language.keywordGroups?[["c", "cpp"].contains(language.id) ? "type1" : "instre2"] ?? []
        )
        documentationKeywords = Set(language.keywordGroups?["type2"] ?? [])
    }

    /// 业务作用：在固定语言定义下识别当前行并更新其后续词法状态。
    /// 参数说明:
    /// - text: 当前完整行或连续片段。
    /// - base: 当前片段在原始正文中的 UTF-8 起点。
    /// - state: 当前流程独立持有的行首状态，结束后推进到下一行。
    /// 返回：当前片段的语法呈现范围，不修改正文。
    public func highlight(_ text: String, base: Int, state: inout SyntaxState) -> [SyntaxToken] {
        if language.id == "registry" {
            return RegistryLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                deadline: deadline,
                state: &state
            )
        }
        if ["ini", "props", "diff", "makefile", "ihex", "srec", "tehex", "tex"].contains(language.id) {
            let mode: LineLexicalMode =
                language.id == "makefile"
                ? .makefile : (LineLexicalMode(rawValue: language.id) ?? .properties)
            return PropertyLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                mode: mode,
                directives: language.id == "makefile" ? language.keywords : [],
                deadline: deadline,
                state: &state
            )
        }
        if ["escseq", "errorlist"].contains(language.id) {
            return ANSILexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.terminalStyles,
                errorList: language.id == "errorlist",
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "c" || language.id == "cpp" {
            return CLexing.highlight(
                text,
                base: base,
                language: language.id,
                keywords: keywords,
                secondaryKeywords: secondaryKeywords,
                documentationKeywords: documentationKeywords,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "json" || language.id == "json5" {
            return JSONLexing.highlight(
                text,
                base: base,
                extended: language.id == "json5",
                rules: language.identifierRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "python" {
            return PythonLexing.highlight(
                text,
                base: base,
                keywords: keywords,
                secondaryKeywords: secondaryKeywords,
                rules: language.identifierRules,
                snapshot: snapshot,
                deadline: deadline,
                state: &state
            )
        }
        return SyntaxEngine.scan(
            text,
            base: base,
            language: language,
            keywords: keywords,
            state: &state
        )
    }
}

public enum SyntaxEngine {
    /// 业务作用：扫描固定行片段并传播跨行状态，不把呈现属性写回正文。
    /// 参数说明:
    /// - text: 逻辑行或连续片段。
    /// - base: 片段在快照中的 UTF-8 起点。
    /// - language: 当前语言规则。
    /// - state: 上一个安全边界的词法状态，完成后更新。
    /// 返回：用于独立绘制的语法范围。
    public static func highlight(
        _ text: String,
        base: Int,
        language: LanguageDefinition,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        SyntaxScanner(language: language).highlight(text, base: base, state: &state)
    }

    /// 业务作用：复用已确认的资源集合，维护当前片段的词法呈现并传播跨行注释状态。
    /// 参数说明:
    /// - text: 当前片段。
    /// - base: 原始正文字节起点。
    /// - language: 固定语言定义。
    /// - keywords: 与该定义一同建立的关键字集合。
    /// - state: 本流程独立词法状态。
    /// 返回：原始坐标中的样式片段，不产生编辑事务。
    static func scan(
        _ text: String,
        base: Int,
        language: LanguageDefinition,
        keywords: Set<String>,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        if ["normal", "nfo"].contains(language.id) {
            return []
        }
        let bytes = Array(text.utf8)
        var result: [SyntaxToken] = []
        var i = 0
        /// 业务作用：只在当前片段内比较词法起止标记，拒绝越界读取。
        /// 参数说明:
        /// - value: 待匹配的字面标记。
        /// - at: 当前片段字节位置。
        /// 返回：原字节完全匹配时为真。
        func matches(_ value: String, at: Int) -> Bool {
            let token = Array(value.utf8)
            return !token.isEmpty && at + token.count <= bytes.count
                && bytes[at..<(at + token.count)].elementsEqual(token)
        }
        /// 业务作用：把局部词法片段转换为所属文档的呈现范围。
        /// 参数说明:
        /// - start: 片段内起始字节。
        /// - end: 不包含的结束字节。
        /// - kind: 呈现类型。
        /// 返回：非空片段进入语法结果，不产生正文修改。
        func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if end > start {
                result.append(
                    SyntaxToken(
                        range: ByteRange(
                            base + start,
                            base + end
                        ),
                        kind: kind
                    )
                )
            }
        }
        if language.id == "markdown", bytes.first == 35 {
            emit(0, bytes.count, .heading)
            return result
        }
        while i < bytes.count {
            let start = i
            if !state.blockEnd.isEmpty {
                while i < bytes.count && !matches(state.blockEnd, at: i) {
                    i += 1
                }
                if i < bytes.count {
                    i += state.blockEnd.utf8.count
                    state.blockEnd = ""
                }
                emit(start, i, .comment)
            }
            else if matches(language.lineComment, at: i) {
                emit(i, bytes.count, .comment)
                break
            }
            else if matches(language.blockStart, at: i), !language.blockEnd.isEmpty {
                state.blockEnd = language.blockEnd
                i += language.blockStart.utf8.count
                while i < bytes.count && !matches(state.blockEnd, at: i) {
                    i += 1
                }
                if i < bytes.count {
                    i += state.blockEnd.utf8.count
                    state.blockEnd = ""
                }
                emit(start, i, .comment)
            }
            else if bytes[i] == 34 || bytes[i] == 39 || bytes[i] == 96 {
                let quote = bytes[i]
                i += 1
                while i < bytes.count {
                    if bytes[i] == 92 {
                        i = min(bytes.count, i + 2)
                    }
                    else if bytes[i] == quote {
                        i += 1
                        break
                    }
                    else {
                        i += 1
                    }
                }
                emit(start, i, .string)
            }
            else if (48...57).contains(bytes[i]) {
                i += 1
                while i < bytes.count
                    && ((48...57).contains(bytes[i]) || (65...70).contains(bytes[i])
                        || (97...102).contains(bytes[i]) || [46, 120, 88, 95].contains(bytes[i]))
                {
                    i += 1
                }
                emit(start, i, .number)
            }
            else if isWord(bytes[i]) {
                i += 1
                while i < bytes.count && (isWord(bytes[i]) || (48...57).contains(bytes[i])) {
                    i += 1
                }
                let word = String(decoding: bytes[start..<i], as: UTF8.self)
                if keywords.contains(word) || keywords.contains(word.lowercased()) {
                    emit(start, i, .keyword)
                }
            }
            else if bytes[i] == 60 && ["xml", "html", "php", "jsp", "asp"].contains(language.id) {
                i += 1
                while i < bytes.count && bytes[i] != 62 {
                    i += 1
                }
                if i < bytes.count {
                    i += 1
                }
                emit(start, i, .tag)
            }
            else {
                i += 1
            }
        }
        return result
    }

    /// 业务作用：识别词法标识符边界，UTF-8 非 ASCII 字节不被当成标点截断。
    /// 参数说明:
    /// - byte: 当前字节。
    /// 返回：可属于标识符的字节。
    static func isWord(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }
}
