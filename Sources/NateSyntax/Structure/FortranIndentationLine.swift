import Foundation
import NateCore

struct FortranIndentationLine {
    private static let modernStructureWords: Set<String> = [
        "block", "blockdata", "change", "changeteam", "endblock", "endblockdata", "endteam",
        "rank", "selectcase", "selectrank", "selecttype", "team",
    ]
    enum Block: String {
        case program, module, submodule, subroutine, function, interface
        case block, blockdata, associate, critical, select, forall, type, team
        case selectCase = "selectcase"
        case selectRank = "selectrank"
        case selectType = "selecttype"
        case masking = "where"
        case conditional = "if"
        case loop = "do"

        /// 业务作用：裸 END 只可结束允许省略终止类别的程序单元。
        /// 参数说明: 无。
        /// 返回：规范允许现有单元使用裸 END 时为真。
        var usesBareEnd: Bool {
            [.program, .module, .submodule, .subroutine, .function, .blockdata].contains(self)
        }

        /// 业务作用：三种 SELECT 块分别拥有分支，但共同使用 END SELECT 关闭。
        /// 参数说明: 无。
        /// 返回：实际开端属于 CASE、RANK 或 TYPE 选择结构时为真。
        var usesSelectionEnd: Bool {
            [.selectCase, .selectRank, .selectType].contains(self)
        }
    }

    enum Event {
        case neutral
        case opening(Block, name: String?)
        case branch(Block, name: String?, levels: Int)
        case closing(Block?, name: String?)
    }

    struct Atom {
        let range: ByteRange
        let value: String
        let keyword: Bool
        let identifier: Bool
    }

    let atoms: [Atom]
    let opaque: [SyntaxToken]
    let prefix: ByteRange
    let crossesStatements: Bool
    let beginsContinuation: Bool
    let endsContinuation: Bool
    let directive: Bool

    /// 业务作用：Fortran 结构只使用当前格式原生词法确认过的水平空白、关键字和标点，注释与字面保持独立。
    /// 参数说明:
    /// - bytes: 当前不含结束符的完整原字节。
    /// - range: 与原字节一致的真实物理行范围。
    /// - tokens: 同一原始范围的原生词法结果。
    /// - languageID: 当前确定的自由格式或固定格式语言身份。
    /// - minimumCodeOffset: 固定格式已确认的标签和续接栏，普通输入为零。
    /// - check: 本次各行和光标共用的继续资格。
    /// 返回：有界词元及原始前缀；没有完整词法或超量时不交付部分结构。
    init(
        bytes: [UInt8],
        range: ByteRange,
        tokens: [SyntaxToken],
        languageID: String,
        minimumCodeOffset: Int,
        check: () throws -> Void
    ) throws {
        var leading = 0
        while leading < bytes.count, bytes[leading] == 32 || bytes[leading] == 9 {
            if leading & 255 == 0 {
                try check()
            }
            leading += 1
        }
        prefix = ByteRange(range.lower, range.lower + leading)
        let directiveStyle = languageID + ":11"
        directive =
            leading < bytes.count && bytes[leading] == 35
            || tokens.contains {
                $0.lexicalStyle == directiveStyle
            }
        opaque = tokens.filter(\.isStructureOpaque)
        let keywordStyle = languageID + ":8"
        let identifierStyle = languageID + ":7"
        let freeForm = languageID == "fortran"
        var atoms: [Atom] = []
        var index = max(leading, minimumCodeOffset)
        var tokenIndex = 0
        while index < bytes.count {
            try check()
            while tokenIndex < tokens.count && tokens[tokenIndex].range.upper <= range.lower + index {
                tokenIndex += 1
            }
            let token =
                tokenIndex < tokens.count && tokens[tokenIndex].range.lower <= range.lower + index
                ? tokens[tokenIndex] : nil
            if token?.kind == .comment {
                break
            }
            let byte = bytes[index]
            if byte == 32 || byte == 9 {
                index += 1
                continue
            }
            // 只有当前可靠的词法类别能授权结构识别。字面会保留为一个参数，内部字节不能视作语句。
            guard atoms.count < 65_536 else {
                throw NateError.message("Fortran 结构缩进单行超过 65536 个有效词元。")
            }
            let start = index
            if let token, token.isStructureOpaque {
                index = min(bytes.count, token.range.upper - range.lower)
                atoms.append(
                    Atom(
                        range: ByteRange(range.lower + start, range.lower + index),
                        value: "",
                        keyword: false,
                        identifier: false
                    )
                )
                continue
            }
            let word = Self.nameStart(byte)
            if word || (48...57).contains(byte) {
                index += 1
                while index < bytes.count, Self.nameStart(bytes[index]) || (48...57).contains(bytes[index]) {
                    if index & 255 == 0 {
                        try check()
                    }
                    index += 1
                }
            }
            else {
                index += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
            }
            let value = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
            atoms.append(
                Atom(
                    range: ByteRange(range.lower + start, range.lower + index),
                    value: value,
                    // 主词表未包含少数新语句，只有原生已确认为普通名称且完全匹配专用词时才进入结构判断。
                    keyword: word
                        && (token?.lexicalStyle == keywordStyle
                            || token?.lexicalStyle == identifierStyle
                                && Self.modernStructureWords.contains(value)),
                    identifier: word
                )
            )
        }
        self.atoms = atoms
        beginsContinuation = freeForm && atoms.first?.value == "&"
        endsContinuation = freeForm && atoms.last?.value == "&"
        crossesStatements = atoms.contains { $0.value == ";" }
    }

    /// 业务作用：复用共同的按字节确认，光标在未结束字面、中间名称或注释内时只继承原缩进。
    /// 参数说明:
    /// - position: 当前换行目标的原字节位置。
    /// 返回：安全代码边界内从行首起的完整词元，未知输入范围为空。
    func prefixAtoms(at position: Int) -> ArraySlice<Atom>? {
        let index = Self.firstEnding(after: position, count: atoms.count) { atoms[$0].range.upper }
        let protectedIndex = Self.firstEnding(after: position - 1, count: opaque.count) {
            opaque[$0].range.upper
        }
        if protectedIndex < opaque.count, opaque[protectedIndex].range.lower < position {
            let token = opaque[protectedIndex]
            if position < token.range.upper || token.kind == .comment || token.lexicalStyle.hasSuffix(":5") {
                return nil
            }
        }
        guard index == atoms.count || atoms[index].range.lower >= position else {
            return nil
        }
        return atoms[..<index]
    }

    /// 业务作用：只在当前实际选区之后仍有一条完整关闭声明时，授权对齐被保留的结构。
    /// 参数说明:
    /// - position: 用户真实替换范围的结束字节。
    /// - boundary: 当前语句的实际终止边界，不能越过语句分隔符。
    /// 返回：后续完整语句及第一字节位置，词元被部分选中时为空。
    func suffixAtoms(at position: Int, endingAt boundary: Int) -> ArraySlice<Atom>? {
        let index = Self.firstEnding(after: position, count: atoms.count) { atoms[$0].range.upper }
        let end = Self.firstEnding(after: boundary, count: atoms.count) { atoms[$0].range.upper }
        guard index < end, atoms[index].range.lower >= position else {
            return nil
        }
        return atoms[index..<end]
    }

    /// 业务作用：只用词法器确认的完整首语句识别块、分支和闭合，Fortran 同名变量、标签循环及调用不会打开结构。
    /// 参数说明:
    /// - source: 插入点之前或将在其后保留的全部完整词元。
    /// - check: 所有光标共同拥有的截止和继续资格。
    /// 返回：语句的结构角色，未确认的声明按普通语句处理。
    static func classify(_ source: ArraySlice<Atom>, check: () throws -> Void) throws -> Event {
        var words = source
        if let first = words.first, !first.value.isEmpty,
            first.value.utf8.allSatisfy({ (48...57).contains($0) })
        {
            words = words.dropFirst()
        }
        var name: String?
        // 声明中的双冒号保留给声明语法，单冒号才引入可选结构名。
        if words.count >= 2, words[words.startIndex].identifier, words[words.startIndex + 1].value == ":",
            words.count == 2 || words[words.startIndex + 2].value != ":"
        {
            name = words[words.startIndex].value
            words = words.dropFirst(2)
        }
        guard let first = words.first, first.keyword else {
            return .neutral
        }
        let rest = words.dropFirst()
        let next = rest.first?.value
        if first.value == "end" {
            if rest.isEmpty {
                return .closing(nil, name: nil)
            }
            if next == "block", rest.count >= 2, rest[rest.startIndex + 1].value == "data" {
                let unit = rest.dropFirst(2)
                guard unit.isEmpty || unit.count == 1 && unit.first?.identifier == true else {
                    return .neutral
                }
                return .closing(.blockdata, name: unit.first?.value)
            }
            if next == "team", rest.first?.keyword == true {
                return try FortranSynchronization.closesTeam(rest.dropFirst(), check: check)
            }
            if let block = next.flatMap(Block.init(rawValue:)), rest.first?.keyword == true,
                rest.count <= 2, rest.count == 1 || rest.last?.identifier == true
            {
                return .closing(block, name: rest.count == 2 ? rest.last?.value : nil)
            }
            return .neutral
        }
        if first.value == "endteam" {
            return try FortranSynchronization.closesTeam(rest, check: check)
        }
        if first.value.hasPrefix("end"),
            let block = Block(rawValue: String(first.value.dropFirst(3))),
            rest.count <= 1, rest.isEmpty || rest.first?.identifier == true
        {
            return .closing(block, name: next)
        }
        switch first.value {
        case "if", "where", "forall":
            guard let block = Block(rawValue: first.value),
                let end = try parenthesisEnd(in: rest, check: check)
            else {
                return .neutral
            }
            let tail = rest.suffix(from: end + 1)
            if block == .conditional {
                guard tail.count == 1, tail.first?.value == "then", tail.first?.keyword == true else {
                    return .neutral
                }
            }
            else if !tail.isEmpty {
                return .neutral
            }
            return .opening(block, name: name)
        case "else", "elseif":
            let condition = first.value == "elseif" ? rest : rest.dropFirst()
            if first.value == "else", rest.isEmpty || rest.count == 1 && rest.first?.identifier == true,
                next != "if"
            {
                return .branch(.conditional, name: rest.first?.identifier == true ? next : nil, levels: 1)
            }
            if first.value == "elseif" || next == "if",
                let end = try parenthesisEnd(in: condition, check: check)
            {
                let tail = condition.suffix(from: end + 1)
                if tail.first?.value == "then", tail.first?.keyword == true, tail.count <= 2 {
                    return .branch(.conditional, name: tail.count == 2 ? tail.last?.value : nil, levels: 1)
                }
            }
            return .neutral
        case "select", "selectcase", "selecttype", "selectrank":
            let spaced = first.value == "select"
            let flavor = spaced ? "select" + (next ?? "") : first.value
            let selector = spaced ? rest.dropFirst() : rest
            guard let block = Block(rawValue: flavor), block.usesSelectionEnd,
                let end = try parenthesisEnd(in: selector, check: check), end + 1 == selector.endIndex
            else {
                return .neutral
            }
            return .opening(block, name: name)
        case "case", "class", "rank", "type":
            let block: Block
            switch first.value {
            case "case":
                block = .selectCase
            case "rank":
                block = .selectRank
            default:
                block = .selectType
            }
            if first.value == "type" {
                if name == nil, let declared = try FortranDerivedType.name(in: rest, check: check) {
                    return .opening(.type, name: declared)
                }
                guard next == "is" else {
                    return .neutral
                }
            }
            if first.value == "class", next != "is" && next != "default" {
                return .neutral
            }
            let selector = block == .selectType && next == "is" ? rest.dropFirst() : rest
            if let end = try parenthesisEnd(in: selector, check: check),
                end + 1 == selector.endIndex
                    || end + 2 == selector.endIndex && selector.last?.identifier == true
            {
                return .branch(
                    block,
                    name: selector.indices.contains(end + 1) ? selector[end + 1].value : nil,
                    levels: 2
                )
            }
            if next == "default", rest.count == 1 || rest.count == 2 && rest.last?.identifier == true {
                return .branch(block, name: rest.count == 2 ? rest.last?.value : nil, levels: 2)
            }
            return .neutral
        case "do":
            guard next != "=", next != "(", next?.utf8.first.map({ !(48...57).contains($0) }) != false else {
                return .neutral
            }
            return .opening(.loop, name: name)
        case "block":
            if rest.isEmpty {
                return .opening(.block, name: name)
            }
            guard name == nil, next == "data" else {
                return .neutral
            }
            let unit = rest.dropFirst()
            guard unit.isEmpty || unit.count == 1 && unit.first?.identifier == true else {
                return .neutral
            }
            return .opening(.blockdata, name: unit.first?.value)
        case "blockdata":
            guard name == nil, rest.isEmpty || rest.count == 1 && rest.first?.identifier == true else {
                return .neutral
            }
            return .opening(.blockdata, name: next)
        case "associate":
            guard let end = try parenthesisEnd(in: rest, check: check), end + 1 == rest.endIndex else {
                return .neutral
            }
            return .opening(.associate, name: name)
        case "critical":
            return try FortranSynchronization.opensCritical(rest, check: check)
                ? .opening(.critical, name: name) : .neutral
        case "change", "changeteam":
            guard first.value == "changeteam" || next == "team" && rest.first?.keyword == true else {
                return .neutral
            }
            let arguments = first.value == "change" ? rest.dropFirst() : rest
            return try FortranSynchronization.opensTeam(arguments, check: check)
                ? .opening(.team, name: name) : .neutral
        case "program", "module", "subroutine", "function", "interface", "submodule":
            if first.value == "module", ["procedure", "function", "subroutine"].contains(next ?? "") {
                return .neutral
            }
            guard let block = Block(rawValue: first.value), next != "=", next != "(" || block == .submodule
            else {
                return .neutral
            }
            if block == .submodule || block == .interface {
                return .opening(block, name: rest.last?.identifier == true ? rest.last?.value : nil)
            }
            guard rest.first?.identifier == true else {
                return .neutral
            }
            return .opening(block, name: next)
        default:
            return .neutral
        }
    }

    /// 业务作用：派生分支和条件须以真实平衡括号结束，字面及后半截选择不能伪造 THEN 或 CASE 条件。
    /// 参数说明:
    /// - atoms: 已确认代码词元所属的实际范围。
    /// - check: 共用的继续资格。
    /// 返回：从第一个左圆括号匹配出的真实右端索引。
    private static func parenthesisEnd(in atoms: ArraySlice<Atom>, check: () throws -> Void) throws -> Int? {
        guard atoms.first?.value == "(" else {
            return nil
        }
        var depth = 0
        for index in atoms.indices {
            if index & 255 == 0 {
                try check()
            }
            switch atoms[index].value {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return index
                }
            default:
                break
            }
        }
        return nil
    }

    /// 业务作用：从有序的原字节词元定位输入边界，多个目标不会顺序重扫整行。
    /// 参数说明:
    /// - position: 当前目标的原字节位置。
    /// - count: 已确认范围的数量。
    /// - end: 对应项的真实排他结束位置。
    /// 返回：结束位置严格在目标之后的首项，全部结束时为 count。
    private static func firstEnding(after position: Int, count: Int, end: (Int) -> Int) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if end(middle) <= position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower
    }

    /// 业务作用：Fortran 名称关键词采用固定 ASCII 边界，任一非名称字节不能合并到结构名称。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：可能处于名称中的 ASCII 字母或下划线时为真。
    private static func nameStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }
}
