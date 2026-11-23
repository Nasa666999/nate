import Foundation
import NateCore

struct PropertyLexing {
    let bytes: [UInt8]
    let base: Int
    let styles: [String: LanguageTokenStyle]
    let mode: LineLexicalMode
    let directives: [String]
    var budget: ANSILexingBudget
    var tokens: [SyntaxToken] = []

    /// 业务作用：内置逐行词法固定物理行与资源身份，保留原字节而不执行配置、补丁或命令。
    /// 参数说明:
    /// - text: 当前完整行或有固定快照证据的连续分段。
    /// - base: 当前片段在正文中的原始 UTF-8 起点。
    /// - snapshot: 用于确认来源及同一物理行边界的固定快照。
    /// - styles: 随当前语言定义固定的词法样式。
    /// - mode: 当前语言采用的独立逐行规则。
    /// - directives: 按原始字节及顺序保留的 Makefile 指令名称，空词表不猜测额外关键字。
    /// - deadline: 本次完整语法任务的共同截止。
    /// - state: 当前任务状态，失败只设置诊断。
    /// 返回：完整确认后裁回当前片段的有限词元；来源、容量、取消或截止不满足时整体拒绝。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        styles: [String: LanguageTokenStyle]?,
        mode: LineLexicalMode = .properties,
        directives: [String] = [],
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(
                deadline: deadline,
                maximumSteps: [.makefile, .ihex, .srec, .tehex].contains(mode) ? 8_388_608 : 4_194_304
            )
            try budget.check()
            if mode == .makefile {
                // 词表必须先具有完整容量资格，超限不能截成另一套规则后继续着色。
                guard directives.count <= 4096 else {
                    throw NateError.message("Makefile 指令名称超过 4096 项。")
                }
                var directiveBytes = 0
                for directive in directives {
                    try budget.consume()
                    guard directive.utf8.count <= 1_048_576 - directiveBytes else {
                        throw NateError.message("Makefile 指令词表超过 1 MiB。")
                    }
                    directiveBytes += directive.utf8.count
                }
            }
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                let styles, styles.count <= 256,
                mode.requiredStyles.allSatisfy({
                    styles[String($0)] != nil
                })
            else {
                throw NateError.message("当前语言高亮缺少完整样式或超出行范围。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            let bytes: [UInt8]
            let origin: Int
            if let snapshot {
                let tree = snapshot.text
                // 分段必须与同一来源的完整标量及 CRLF 一致，不能从邻近文本猜测键、节标题或补丁标记。
                guard requested.upper <= tree.byteCount,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: requested.lower - 1) == 13 && tree.byte(at: requested.lower) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("当前语言高亮来源与固定快照不一致。")
                }
                let range = try ANSILexing.physicalRange(requested, tree: tree, budget: &budget)
                bytes = tree.bytes(in: range)
                origin = range.lower
            }
            else {
                bytes = Array(text.utf8)
                origin = base
            }
            var scanner = PropertyLexing(
                bytes: bytes,
                base: origin,
                styles: styles,
                mode: mode,
                directives: directives,
                budget: budget
            )
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count {
                    try scanner.budget.consume()
                    let byte = bytes[end]
                    end += 1
                    if byte == 13 {
                        if end < bytes.count, bytes[end] == 10 {
                            end += 1
                        }
                        break
                    }
                    if byte == 10 {
                        break
                    }
                }
                if mode == .diff {
                    try scanner.diffLine(start, end)
                }
                else if mode == .makefile {
                    try scanner.makeLine(start, end)
                }
                else if [.ihex, .srec, .tehex].contains(mode) {
                    try scanner.hexLine(start, end)
                }
                else if mode == .tex {
                    try scanner.texLine(start, end)
                }
                else {
                    try scanner.line(start, end)
                }
                start = end
            }
            var result: [SyntaxToken] = []
            for token in scanner.tokens {
                try scanner.budget.consume()
                let lower = max(requested.lower, token.range.lower)
                let upper = min(requested.upper, token.range.upper)
                if upper > lower {
                    result.append(
                        SyntaxToken(
                            range: ByteRange(lower, upper),
                            kind: token.kind,
                            foreground: token.foreground,
                            background: token.background,
                            fontStyle: token.fontStyle,
                            lexicalStyle: token.lexicalStyle,
                            nativeStyle: token.nativeStyle
                        )
                    )
                }
            }
            // 全部范围与末次取消复验先于返回，不发布半个配置词元或差异行的呈现。
            try scanner.budget.check()
            return result
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：保留基准配置词法的前缀优先级，行内注释外观与引号不改写值的身份。
    /// 参数说明:
    /// - start: 当前物理行起点。
    /// - end: 包含真实结束符的末边界。
    /// 返回：当前物理行的完整样式，前导空白与所属键、注释或节保持同一类别。
    mutating func line(_ start: Int, _ end: Int) throws {
        var cursor = start
        while cursor < end, Self.space(bytes[cursor]) {
            try budget.consume()
            cursor += 1
        }
        guard cursor < end else {
            try emit(start, end, style: 0)
            return
        }
        switch bytes[cursor] {
        case 35, 33, 59:
            try emit(start, end, style: 1)
        case 91:
            try emit(start, end, style: 2)
        case 64:
            try emit(start, cursor + 1, style: 4)
            try emit(cursor + 1, end, style: 0)
        default:
            while cursor < end, bytes[cursor] != 61 && bytes[cursor] != 58 {
                try budget.consume()
                cursor += 1
            }
            if cursor < end {
                try emit(start, cursor, style: 5)
                try emit(cursor, cursor + 1, style: 3)
                try emit(cursor + 1, end, style: 0)
            }
            else {
                try emit(start, end, style: 0)
            }
        }
    }

    /// 业务作用：配置前缀只跳过规定的 ASCII 空白，Unicode 空白不被静默重新解释。
    /// 参数说明:
    /// - byte: 原始源字节。
    /// 返回：属于 ASCII 空格、Tab 或行内控制空白时为真。
    static func space(_ byte: UInt8) -> Bool {
        byte == 32 || byte >= 9 && byte <= 13
    }

    /// 业务作用：有限词元同时保留资源颜色、字体与词法身份，样式不进入正文事务。
    /// 参数说明:
    /// - start: 当前上下文内的起点。
    /// - end: 当前上下文内的末边界。
    /// - style: 当前语言的固定样式编号。
    /// 返回：完整非空范围加入结果；超出容量时整体失败。
    mutating func emit(_ start: Int, _ end: Int, style: Int) throws {
        guard end > start else {
            return
        }
        guard tokens.count < 65_536,
            let attributes = styles[String(style)] ?? (mode == .diff ? styles["0"] : nil)
        else {
            throw NateError.message("当前语言高亮超过词元容量或缺少样式定义。")
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(base + start, base + end),
                kind: mode.kinds[style],
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: mode.rawValue + ":" + String(style)
            )
        )
    }
}
