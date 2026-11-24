import Foundation
import NateCore

public struct FoldRegion: Sendable, Equatable {
    public let range: ByteRange
    public let startLine: Int
    public let endLine: Int
    public let level: Int
}

public struct FoldIndex: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let regions: [FoldRegion]
    private let parents: [Int?]

    /// 业务作用：只为已具备明确结构规则的语言启用折叠，纯文本与未定义规则的 UDL 不猜测代码块。
    /// 参数说明:
    /// - language: 当前内置语言资源。
    /// - udl: 独立用户语言；其折叠需采用自己的字面规则。
    /// 返回：当前语言具有语法、注释、预处理、缩进、配置节、差异或 UDL 明确字面层级规则时为真。
    public static func supports(language: LanguageDefinition?, udl: UDLDefinition?) -> Bool {
        if let udl {
            return udl.allowFoldOfComments || UDLFoldRules(definition: udl).enabled
        }
        return [
            "python", "ini", "props", "diff", "registry", "ihex", "tex", "latex", "yaml", "lua", "mssql",
            "sql", "toml", "cmake", "pascal", "asm", "fortran", "fortran77", "autoit", "bash",
        ]
        .contains(
            language?.id ?? ""
        )
            || !openers(for: language?.id ?? "").isEmpty
    }

    /// 业务作用：将同一修订的词法证据按语言规则转成真实行折叠范围，缺少完整分析证据时不隐藏正文。
    /// 参数说明:
    /// - snapshot: 配对所属的完整正文快照。
    /// - brackets: 已完成且与快照身份一致的结构证据。
    /// - language: 当前内置语言定义。
    /// - udl: 当前独立 UDL，存在时按自身明确字面及注释分组规则建立范围。
    /// 返回：最多 65536 个完整多行范围及父级索引；身份、数量或时间预算不满足时拒绝发布。
    public init(
        snapshot: DocumentSnapshot,
        brackets: BracketIndex,
        language: LanguageDefinition?,
        udl: UDLDefinition? = nil
    ) throws {
        guard brackets.documentID == snapshot.id, brackets.revision == snapshot.revision else {
            // 不同正文的字节范围不能用于隐藏当前行，缺少一致证据时保留全部正文可见。
            throw NateError.staleRevision
        }
        let allowed = Self.openers(for: language?.id ?? "")
        let deadline = ContinuousClock.now.advanced(
            by: [
                "python", "ini", "props", "diff", "c", "cpp", "registry", "ihex", "tex", "latex", "lisp",
                "scheme", "rust", "yaml", "powershell", "objc", "r", "lua", "mssql", "sql", "css", "toml",
                "cmake", "pascal", "asm", "fortran", "fortran77", "autoit", "bash",
            ].contains(
                language?.id ?? ""
            ) || language?.usesSharedCLexer == true || udl != nil
                ? .seconds(5) : .seconds(1)
        )
        var candidates: [FoldRegion] = []
        if let udl {
            candidates = try UDLFolding.regions(snapshot: snapshot, definition: udl, deadline: deadline)
        }
        else if let language, language.id == "lua" {
            candidates = try LuaFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "r" {
            candidates = try RFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "autoit" {
            candidates = try AutoItFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else if let language, language.id == "bash" {
            candidates = try BashFolding.regions(snapshot: snapshot, deadline: deadline)
        }
        else if let language, ["fortran", "fortran77"].contains(language.id) {
            candidates = try FortranFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else if let language, language.id == "asm" {
            candidates = try ASMFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "pascal" {
            candidates = try PascalFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "cmake" {
            candidates = try CMakeFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "toml" {
            candidates = try TOMLFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "css" {
            candidates = try CSSFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "sql" {
            candidates = try SQLFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "mssql" {
            candidates = try MSSQLFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "objc" {
            candidates = try ObjCFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "powershell" {
            candidates = try PowerShellFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else if let language, language.id == "yaml" {
            candidates = try YAMLFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "rust" {
            candidates = try RustFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, ["lisp", "scheme"].contains(language.id) {
            candidates = try LispFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "latex" {
            candidates = try LatexFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "tex" {
            candidates = try TeXFolding.regions(snapshot: snapshot, deadline: deadline)
        }
        else if let language, language.id == "ihex" {
            candidates = try IHexFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "registry" {
            candidates = try RegistryFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else if let language, language.usesSharedCLexer {
            candidates = try CFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, language.id == "python" {
            candidates = try PythonFolding.regions(snapshot: snapshot, language: language, deadline: deadline)
        }
        else if let language, ["ini", "props"].contains(language.id) {
            candidates = try PropertyFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else if let language, language.id == "diff" {
            candidates = try DiffFolding.regions(
                snapshot: snapshot,
                language: language,
                deadline: deadline
            )
        }
        else {
            for (offset, pair) in brackets.structuralPairs.enumerated() {
                if offset & 255 == 0 {
                    try Self.check(deadline)
                }
                guard allowed.contains(pair.opener) else {
                    continue
                }
                let start = snapshot.text.lineNumber(at: pair.range.lower)
                let end = snapshot.text.lineNumber(at: pair.range.upper - 1)
                guard end > start else {
                    continue
                }
                guard candidates.count < 65_536 else {
                    throw NateError.message("折叠解析暂停：多行结构数量超过 65536 个。")
                }
                candidates.append(
                    FoldRegion(
                        range: pair.range,
                        startLine: start,
                        endLine: end,
                        level: 0
                    )
                )
            }
        }
        candidates.sort {
            if $0.startLine != $1.startLine {
                return $0.startLine < $1.startLine
            }
            if $0.endLine != $1.endLine {
                return $0.endLine > $1.endLine
            }
            return $0.range.lower < $1.range.lower
        }
        var unique: [FoldRegion] = []
        for candidate in candidates where unique.last?.startLine != candidate.startLine {
            unique.append(candidate)
        }
        var stack: [Int] = []
        var invalid: Set<Int> = []
        for (index, candidate) in unique.enumerated() {
            if index & 255 == 0 {
                try Self.check(deadline)
            }
            while let parent = stack.last, unique[parent].endLine <= candidate.startLine {
                stack.removeLast()
            }
            var crosses = false
            while let parent = stack.last, unique[parent].endLine < candidate.endLine {
                // 独立括号配对允许错误语法中的交叉；折叠不能据此隐藏互相穿越的结构。
                invalid.insert(parent)
                stack.removeLast()
                crosses = true
            }
            if crosses {
                invalid.insert(index)
            }
            stack.append(index)
        }
        var output: [FoldRegion] = []
        var ancestors: [Int?] = []
        stack.removeAll(keepingCapacity: true)
        for (index, candidate) in unique.enumerated() where !invalid.contains(index) {
            while let parent = stack.last, output[parent].endLine <= candidate.startLine {
                stack.removeLast()
            }
            let parent = stack.last
            ancestors.append(parent)
            output.append(
                FoldRegion(
                    range: candidate.range,
                    startLine: candidate.startLine,
                    endLine: candidate.endLine,
                    level: parent.map {
                        output[$0].level + 1
                    } ?? 1
                )
            )
            stack.append(output.count - 1)
        }
        try Self.check(deadline)
        documentID = snapshot.id
        revision = snapshot.revision
        regions = output
        parents = ancestors
    }

    /// 业务作用：边栏和当前块命令共用真实行索引，优先选择本行起始块，否则选择最近的包围块。
    /// 参数说明:
    /// - line: 当前合法逻辑行。
    /// 返回：最近的完整折叠范围，当前行不属于任何结构时为空。
    public func region(at line: Int) -> FoldRegion? {
        var lower = 0
        var upper = regions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if regions[middle].startLine <= line {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        var current: Int? = lower > 0 ? lower - 1 : nil
        while let index = current {
            if regions[index].endLine >= line {
                return regions[index]
            }
            current = parents[index]
        }
        return nil
    }

    /// 业务作用：按语言语法选择可折叠的括号类型，不将普通文本中的配对冒充代码结构。
    /// 参数说明:
    /// - id: 公开语言标识符。
    /// 返回：当前语言使用的结构起始字节；尚无明确规则时为空。
    private static func openers(for id: String) -> Set<UInt8> {
        switch id {
        case "json", "json5": return [123, 91]
        case "lisp", "scheme": return [40]
        case "actionscript", "baanc", "c", "cpp", "cs", "css", "d", "escript", "go", "java",
            "javascript", "javascript.js", "objc", "oscript", "php", "powershell", "r", "rc", "rust",
            "swift", "tcl", "typescript":
            return [123]
        default: return []
        }
    }

    /// 业务作用：折叠范围转换同样受取消和时间约束，不让完整配对后的整理阶段无限占用任务位。
    /// 参数说明:
    /// - deadline: 当前范围转换的截止时刻。
    /// 返回：仍有资格时继续，取消或超时则丢弃未发布范围。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("折叠解析暂停：范围转换超过当前时间预算。")
        }
    }
}
