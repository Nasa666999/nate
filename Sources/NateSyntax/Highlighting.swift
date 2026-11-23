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
    public let fontName: String?
    public let fontSize: Int?
    public let lexicalStyle: String
    public let nativeStyle: UInt8?
    public let foldMarker: SyntaxFoldMarker?

    /// 业务作用：携带可配置语法呈现，样式不进入正文历史。
    /// 参数说明:
    /// - range: 所属快照字节范围。
    /// - kind: 默认主题分类。
    /// - foreground: 资源显式指定的前景色，为空时继承主题。
    /// - background: 资源显式指定的背景色，为空时继承视图底色。
    /// - fontStyle: UDL 粗体、斜体和下划线位集合。
    /// - fontName: 资源指定的字体名称，为空时继承编辑器字体。
    /// - fontSize: 资源指定的一至五百一十二点字号，为空时继承编辑器字号。
    /// - lexicalStyle: 原词法样式身份，为空时采用基础类别；颜色相同不代表词法作用域相同。
    /// - nativeStyle: 已确认的原生数字样式，为空时从有限数字词法身份读取；不改变结构类别。
    /// - foldMarker: 词法过程明确确认的折叠动作及其实际上下文，没有标记时为空。
    /// 返回：独立呈现属性。
    public init(
        range: ByteRange,
        kind: SyntaxKind,
        foreground: String? = nil,
        background: String? = nil,
        fontStyle: Int = 0,
        fontName: String? = nil,
        fontSize: Int? = nil,
        lexicalStyle: String? = nil,
        nativeStyle: UInt8? = nil,
        foldMarker: SyntaxFoldMarker? = nil
    ) {
        self.range = range
        self.kind = kind
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
        self.fontName = fontName
        self.fontSize = fontSize
        self.lexicalStyle = lexicalStyle ?? kind.rawValue
        self.nativeStyle = nativeStyle ?? Self.numericStyle(lexicalStyle)
        self.foldMarker = foldMarker
    }

    /// 业务作用：数字样式保留独立的主题覆盖身份，语义词法名称继续用于结构匹配。
    /// 参数说明:
    /// - identity: 当前已经确认的完整词法身份。
    /// 返回：至多 256 UTF-8 字节且末段为原生数字类别时提供编号，其它身份保持为空。
    private static func numericStyle(_ identity: String?) -> UInt8? {
        guard let identity, identity.utf8.count <= 256,
            let separator = identity.lastIndex(of: ":")
        else {
            return nil
        }
        return UInt8(identity[identity.index(after: separator)...])
    }

    /// 业务作用：代码结构只使用真实代码标点，字符串、注释和宏体不能制造主代码块。
    /// 参数说明: 无。
    /// 返回：当前范围不应贡献代码折叠或结构缩进标点时为真。
    public var isStructureOpaque: Bool {
        kind == .string || kind == .comment || lexicalStyle == "c:preprocessor"
            || lexicalStyle == "objc:9"
            || lexicalStyle == "r:10" || lexicalStyle == "r:11" || lexicalStyle == "lua:9"
            || lexicalStyle == "script:9"
            || lexicalStyle == "nncrontab:2"
            || ["pascal:5", "pascal:6", "pascal:14"].contains(lexicalStyle)
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
    var latex = LatexLexicalState()
    var lisp = LispLexicalState()
    var rust = RustLexicalState()
    var yaml = YAMLLexicalState()
    var powershell = PowerShellLexicalState()
    var objc = ObjCLexicalState()
    var r = RLexicalState()
    var lua = LuaLexicalState()
    var scriptCache = ScriptLexicalCache()
    var mssql = MSSQLLexicalState()
    var mssqlCache = MSSQLLexicalCache()
    var sql = SQLLexicalState()
    var sqlCache = SQLLexicalCache()
    var css = CSSLexicalState()
    var cssCache = CSSLexicalCache()
    var batch = BatchLexicalState()
    var batchCache = BatchLexicalCache()
    var toml = TOMLLexicalState()
    var tomlCache = TOMLLexicalCache()
    var cmake = CMakeLexicalState()
    var cmakeCache = CMakeLexicalCache()
    var pascal = PascalLexicalState()
    var pascalCache = PascalLexicalCache()
    var nncrontab = NncronLexicalState()
    var nncrontabCache = NncronLexicalCache()
    var asm = ASMLexicalState()
    var asmCache = ASMLexicalCache()

    /// 业务作用：为行间词法传播建立中性状态。
    /// 参数说明: 无。
    /// 返回：未处于跨行注释或字符串的状态。
    public init() {}
}

public struct SyntaxScanner: Sendable {
    let language: LanguageDefinition
    let keywords: Set<String>
    let secondaryKeywords: Set<String>
    let globalClasses: Set<String>
    let documentationKeywords: Set<String>
    let snapshot: DocumentSnapshot?
    let deadline: ContinuousClock.Instant
    let rustResource: Data?
    let yamlRules: YAMLRules?
    let powershellRules: PowerShellRules?
    let objcRules: ObjCRules?
    let rRules: RRules?
    let luaRules: LuaRules?
    let scriptRules: ScriptRules?
    let mssqlRules: MSSQLRules?
    let sqlRules: SQLRules?
    let cssRules: CSSRules?
    let batchRules: BatchRules?
    let tomlRules: TOMLRules?
    let cmakeRules: CMakeRules?
    let pascalRules: PascalRules?
    let nncrontabRules: NncronRules?
    let asmRules: ASMRules?

    /// 业务作用：一次后台分析固定语言资源并复用关键字集合，逐行传播不重复构建整份资源。
    /// 参数说明:
    /// - language: 本次分析采用的不可变语言定义。
    /// - snapshot: 完整呈现时用于确认后续字面证据；为空时只传播当前片段的状态。
    /// - deadline: 所属完整操作的共同截止，为空时最多五秒。
    /// 返回：可跨后台任务传递的扫描上下文，词法状态由每个调用流程分别持有。
    public init(
        language: LanguageDefinition,
        snapshot: DocumentSnapshot? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.language = language
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        if language.id == "rust" {
            rustResource = RustLexing.ruleIdentity(language: language, deadline: self.deadline)
        }
        else {
            rustResource = nil
        }
        yamlRules = language.id == "yaml" ? YAMLRules(language: language, deadline: self.deadline) : nil
        powershellRules =
            language.id == "powershell"
            ? PowerShellRules(language: language, deadline: self.deadline) : nil
        objcRules = language.id == "objc" ? ObjCRules(language: language, deadline: self.deadline) : nil
        rRules = language.id == "r" ? RRules(language: language, deadline: self.deadline) : nil
        luaRules = language.id == "lua" ? LuaRules(language: language, deadline: self.deadline) : nil
        mssqlRules = language.id == "mssql" ? MSSQLRules(language: language, deadline: self.deadline) : nil
        sqlRules = language.id == "sql" ? SQLRules(language: language, deadline: self.deadline) : nil
        cssRules = language.id == "css" ? CSSRules(language: language, deadline: self.deadline) : nil
        batchRules = language.id == "batch" ? BatchRules(language: language, deadline: self.deadline) : nil
        tomlRules = language.id == "toml" ? TOMLRules(language: language, deadline: self.deadline) : nil
        cmakeRules = language.id == "cmake" ? CMakeRules(language: language, deadline: self.deadline) : nil
        pascalRules = language.id == "pascal" ? PascalRules(language: language, deadline: self.deadline) : nil
        nncrontabRules =
            language.id == "nncrontab" ? NncronRules(language: language, deadline: self.deadline) : nil
        asmRules = language.id == "asm" ? ASMRules(language: language, deadline: self.deadline) : nil
        scriptRules =
            ["javascript.js", "typescript"].contains(language.id)
            ? ScriptRules(language: language, deadline: self.deadline) : nil
        self.snapshot =
            [
                "python", "escseq", "errorlist", "ini", "props", "diff", "makefile", "registry", "ihex",
                "srec", "tehex", "tex", "latex", "lisp", "scheme", "c", "cpp", "rust", "yaml", "powershell",
                "objc", "r", "lua", "mssql", "sql", "css", "batch", "toml", "cmake", "pascal", "nncrontab",
                "asm",
            ].contains(
                language.id
            ) || language.usesSharedCLexer
            ? snapshot : nil
        if [
            "makefile", "rust", "yaml", "powershell", "objc", "r", "lua", "javascript.js", "typescript",
            "mssql", "sql", "css", "batch", "toml", "cmake", "pascal", "nncrontab", "asm",
        ]
        .contains(language.id) {
            // 独立扫描器已经有界复验有效词表，不能再为未使用的聚合字段建立额外集合。
            keywords = []
            secondaryKeywords = []
            globalClasses = []
            documentationKeywords = []
            return
        }
        keywords = Set(
            (language.usesSharedCLexer || ["python", "lisp", "scheme"].contains(language.id))
                ? language.keywordGroups?["instre1"] ?? language.keywords : language.keywords
        )
        secondaryKeywords = Set(
            language.keywordGroups?[language.usesSharedCLexer ? "type1" : "instre2"] ?? []
        )
        globalClasses = Set(language.usesSharedCLexer ? language.keywordGroups?["instre2"] ?? [] : [])
        documentationKeywords = Set(
            language.usesSharedCLexer && !["c", "cpp"].contains(language.id)
                ? language.keywordGroups?["cppDocumentation"] ?? []
                : language.keywordGroups?["type2"] ?? []
        )
    }

    /// 业务作用：在固定语言定义下识别当前行并更新其后续词法状态。
    /// 参数说明:
    /// - text: 当前完整行或连续片段。
    /// - base: 当前片段在原始正文中的 UTF-8 起点。
    /// - state: 当前流程独立持有的行首状态，结束后推进到下一行。
    /// 返回：当前片段的语法呈现范围，不修改正文。
    public func highlight(_ text: String, base: Int, state: inout SyntaxState) -> [SyntaxToken] {
        // 汇编指令、引号及续行资格属于同一完整规则，语言切换必须撤销旧状态。
        guard state.asm.resource == nil || language.id == "asm" else {
            state.diagnostic = "词法语言已改变，不能继续汇编的原状态。"
            return []
        }
        if language.id == "asm" {
            return ASMLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: asmRules,
                deadline: deadline,
                state: &state
            )
        }
        // nnCron 环境变量及字面资格属于同一完整规则，语言切换不能延续此前的原文状态。
        guard state.nncrontab.resource == nil || language.id == "nncrontab" else {
            state.diagnostic = "词法语言已改变，不能继续 nnCron 的原状态。"
            return []
        }
        if language.id == "nncrontab" {
            return NncronLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: nncrontabRules,
                deadline: deadline,
                state: &state
            )
        }
        // Pascal 声明、汇编及多行字面属于同一完整规则，语言变化必须撤销旧状态资格。
        guard state.pascal.resource == nil || language.id == "pascal" else {
            state.diagnostic = "词法语言已改变，不能继续 Pascal 的原状态。"
            return []
        }
        if language.id == "pascal" {
            return PascalLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: pascalRules,
                deadline: deadline,
                state: &state
            )
        }
        // CMake 引号及变量资格属于同一完整规则，语言变化必须重建连续证据。
        guard state.cmake.resource == nil || language.id == "cmake" else {
            state.diagnostic = "词法语言已改变，不能继续 CMake 的原状态。"
            return []
        }
        if language.id == "cmake" {
            return CMakeLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: cmakeRules,
                deadline: deadline,
                state: &state
            )
        }
        // TOML 后继键名与行元数据属于同一规则，语言变化必须重建连续证据。
        guard state.toml.resource == nil || language.id == "toml" else {
            state.diagnostic = "词法语言已改变，不能继续 TOML 的原状态。"
            return []
        }
        if language.id == "toml" {
            return TOMLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: tomlRules,
                deadline: deadline,
                state: &state
            )
        }
        // Batch 文本命令资格属于完整物理行，语言变化必须重建连续证据。
        guard state.batch.resource == nil || language.id == "batch" else {
            state.diagnostic = "词法语言已改变，不能继续 Batch 的原状态。"
            return []
        }
        if language.id == "batch" {
            return BatchLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: batchRules,
                deadline: deadline,
                state: &state
            )
        }
        // CSS 未决段可以影响此前物理行，语言切换必须重建该语言自己的连续证据。
        guard state.css.resource == nil || language.id == "css" else {
            state.diagnostic = "词法语言已改变，不能继续 CSS 的原状态。"
            return []
        }
        if language.id == "css" {
            return CSSLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: cssRules,
                deadline: deadline,
                state: &state
            )
        }
        // SQL 的引号和物理分类缓存属于自己的规则，切换语言必须显式重建连续状态。
        guard state.sql.resource == nil || language.id == "sql" else {
            state.diagnostic = "词法语言已改变，不能继续 SQL 的原状态。"
            return []
        }
        if language.id == "sql" {
            return SQLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: sqlRules,
                deadline: deadline,
                state: &state
            )
        }
        // T-SQL 前向证据属于自己的语言规则，切换语言必须从中性状态开始，不能继续旧缓存。
        guard state.mssql.resource == nil || language.id == "mssql" else {
            state.diagnostic = "词法语言已改变，不能继续 T-SQL 的原状态。"
            return []
        }
        if language.id == "mssql" {
            return MSSQLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: mssqlRules,
                deadline: deadline,
                state: &state
            )
        }
        if ["javascript.js", "typescript"].contains(language.id) {
            return ScriptLexing.highlight(
                text,
                base: base,
                language: language.id,
                snapshot: snapshot,
                rules: scriptRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "lua" {
            return LuaLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: luaRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "r" {
            return RLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: rRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "objc" {
            return ObjCLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: objcRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "powershell" {
            return PowerShellLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: powershellRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "yaml" {
            return YAMLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: yamlRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "rust" {
            return RustLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                language: language,
                resource: rustResource,
                deadline: deadline,
                state: &state
            )
        }
        if ["lisp", "scheme"].contains(language.id) {
            return LispLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                language: language.id,
                styles: language.lexicalStyles,
                keywords: keywords,
                secondary: secondaryKeywords,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "latex" {
            return LatexLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                deadline: deadline,
                state: &state
            )
        }
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
        if language.usesSharedCLexer {
            return CLexing.highlight(
                text,
                base: base,
                language: language.id,
                keywords: keywords,
                secondaryKeywords: secondaryKeywords,
                globalClasses: globalClasses,
                documentationKeywords: documentationKeywords,
                snapshot: snapshot,
                scriptRules: scriptRules,
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
