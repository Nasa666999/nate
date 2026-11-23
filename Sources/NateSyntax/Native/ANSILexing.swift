import Foundation
import NateCore

struct ANSILexing {
    var bytes: [UInt8]
    var base: Int
    let styles: [String: LanguageTokenStyle]
    let errorList: Bool
    var budget: ANSILexingBudget
    var tokens: [SyntaxToken] = []

    /// 业务作用：终端与诊断模式只解释固定源字节的样式，不执行终端命令或改变正文。
    /// 参数说明:
    /// - text: 当前原始行片段，包含真实结束符。
    /// - base: 片段在固定快照中的原始字节起点。
    /// - snapshot: 完整来源证据，用于跨 Unicode 显示断行确认同一物理行。
    /// - styles: 随语言资源固定的终端日志样式集合。
    /// - errorList: 是否采用诊断分类及 ErrorList 的独立序列规则。
    /// - deadline: 本次完整语法任务的共同截止。
    /// - state: 当前任务状态，失败只发布明确诊断。
    /// 返回：完整物理行确认后裁回当前片段；取消、容量或来源失配时整体拒绝。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        styles: [String: LanguageTokenStyle]?,
        errorList: Bool = false,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(
                deadline: deadline,
                maximumSteps: errorList ? 67_108_864 : 4_194_304
            )
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                let styles, styles.count <= 256,
                styles["0"] != nil, styles[errorList ? "23" : "171"] != nil,
                styles[errorList ? "24" : "172"] != nil
            else {
                throw NateError.message("终端日志高亮缺少完整样式资源或超出行范围，当前范围保持原文。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            let source: [UInt8]
            let origin: Int
            if let snapshot {
                // 展示断行不等于终端物理换行；先验证来源，再有界回看同一 CR/LF 行，不能沿用别处的颜色。
                let tree = snapshot.text
                guard requested.upper <= tree.byteCount,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: requested.lower - 1) == 13 && tree.byte(at: requested.lower) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("终端日志高亮来源与固定快照不一致。")
                }
                let range = try physicalRange(requested, tree: tree, budget: &budget)
                source = tree.bytes(in: range)
                origin = range.lower
            }
            else {
                source = Array(text.utf8)
                origin = base
            }
            var scanner = ANSILexing(
                bytes: source,
                base: origin,
                styles: styles,
                errorList: errorList,
                budget: budget
            )
            try scanner.scan()
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
            // 所有样式与原文端点完整确认后才返回；任何迟到取消都不能留下部分颜色。
            try scanner.budget.check()
            return result
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：跨显示分段读取真实物理行，使 Unicode 分隔符不清除终端样式或截断转义。
    /// 参数说明:
    /// - requested: 已验证的当前显示分段。
    /// - tree: 当前不可变正文树。
    /// - budget: 与后续解析共用的取消、时间及扫描预算。
    /// 返回：至多 1 MiB 的完整物理行上下文；过长时在复制正文前拒绝。
    static func physicalRange(
        _ requested: ByteRange,
        tree: PieceTree,
        budget: inout ANSILexingBudget
    ) throws -> ByteRange {
        var lower = requested.lower
        var upper = requested.upper
        while lower > 0, let byte = tree.byte(at: lower - 1), byte != 10 && byte != 13 {
            try budget.consume()
            guard upper - lower < 1_048_576 else {
                throw NateError.message("词法高亮物理行超过 1 MiB，正文保留。")
            }
            lower -= 1
        }
        while upper < tree.byteCount, tree.byte(at: upper - 1) != 10 && tree.byte(at: upper - 1) != 13 {
            try budget.consume()
            guard upper - lower < 1_048_576 else {
                throw NateError.message("词法高亮物理行超过 1 MiB，正文保留。")
            }
            let byte = tree.byte(at: upper)
            upper += 1
            if byte == 13, tree.byte(at: upper) == 10 {
                guard upper - lower < 1_048_576 else {
                    throw NateError.message("词法高亮物理行超过 1 MiB，正文保留。")
                }
                upper += 1
            }
        }
        return ByteRange(lower, upper)
    }

    /// 业务作用：每个 CR/LF 物理行重新确定基础类别，序列只改变同一行后续文字的呈现。
    /// 参数说明: 无。
    /// 返回：逐行生成完整样式；没有序列的诊断行仍保留自己的完整类别。
    mutating func scan() throws {
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count {
                try budget.consume()
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
            try line(start, end)
            start = end
        }
    }

    /// 业务作用：识别 CSI 样式、清行和未知命令，NUL 后不再搜索新的序列但原字节全部保留。
    /// 参数说明:
    /// - start: 物理行起始位置。
    /// - end: 包含实际结束符的物理行末边界。
    /// 返回：生成当前行所有范围；清行命令仅着色，绝不删除或重排文字。
    mutating func line(_ start: Int, _ end: Int) throws {
        var cursor = start
        var defaultStyle = 0
        if errorList {
            var recognition = ErrorListRecognition(
                bytes: Array(bytes[start..<end]),
                budget: budget
            )
            defaultStyle = try recognition.style()
            budget = recognition.budget
        }
        var style = defaultStyle
        let known = errorList ? 23 : 171
        let unknown = errorList ? 24 : 172
        while cursor < end {
            var sequence = cursor
            while sequence < end {
                try budget.consume()
                if bytes[sequence] == 0 {
                    sequence = end
                    break
                }
                if bytes[sequence] == 27, sequence + 1 < end, bytes[sequence + 1] == 91 {
                    break
                }
                sequence += 1
            }
            try emit(cursor, sequence, style: style)
            if sequence == end {
                break
            }
            var finish = sequence + 2
            while finish < end, bytes[finish] != 0, !(bytes[finish] >= 64 && bytes[finish] <= 126) {
                try budget.consume()
                finish += 1
            }
            guard finish < end, bytes[finish] != 0 else {
                try emit(sequence, end, style: unknown)
                break
            }
            let command = bytes[finish]
            try emit(sequence, finish + 1, style: command == 109 || command == 75 ? known : unknown)
            if command == 109 {
                style =
                    try errorList
                    ? diagnosticSequenceStyle(sequence + 2, finish) : sequenceStyle(sequence + 2, finish)
            }
            else if command != 75 {
                style = defaultStyle
            }
            cursor = finish + 1
        }
    }

    /// 业务作用：按基准 ANSI 模式的有限数字组计算前景、背景及亮色身份，单条序列独立解释。
    /// 参数说明:
    /// - start: CSI 参数起点。
    /// - end: 终止命令之前的边界。
    /// 返回：随包样式编号；未提供的控制参数不执行任何终端动作。
    mutating func sequenceStyle(_ start: Int, _ end: Int) throws -> Int {
        var foreground = 0
        var background = 0
        var bold = false
        var cursor = start
        while cursor < end {
            try budget.consume()
            if bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                var value = 0
                var digits = 0
                while cursor < end, bytes[cursor] >= 48 && bytes[cursor] <= 57, digits < 3 {
                    try budget.consume()
                    value = value * 10 + Int(bytes[cursor] - 48)
                    digits += 1
                    cursor += 1
                }
                switch value {
                case 0:
                    foreground = 0
                    background = 0
                    bold = false
                case 1:
                    bold = true
                case 22:
                    bold = false
                case 30...37:
                    foreground = value - 29
                case 90...97:
                    foreground = value - 89
                    bold = true
                case 40...47:
                    background = value - 39
                case 100...107:
                    background = value - 99
                default:
                    break
                }
            }
            else {
                cursor += 1
            }
        }
        let style = foreground + (bold ? 81 : 0) + background * 9
        return style >= 31 ? style + 9 : style
    }

    /// 业务作用：样式与实际原始范围共同发布，相邻同类合并并对整行片段数量设限。
    /// 参数说明:
    /// - start: 当前上下文中的起点。
    /// - end: 当前上下文中的末边界。
    /// - style: 已计算的固定样式编号。
    /// 返回：有限列表中的完整片段；资源缺失或超量时抛错以丢弃全部中间结果。
    mutating func emit(_ start: Int, _ end: Int, style: Int) throws {
        guard end > start else {
            return
        }
        guard let attributes = styles[String(style)] else {
            throw NateError.message("终端日志高亮缺少当前样式定义。")
        }
        let identity = (errorList ? "error:" : "ansi:") + String(style)
        var lower = base + start
        if let previous = tokens.last, previous.lexicalStyle == identity, previous.range.upper == lower {
            lower = previous.range.lower
            tokens.removeLast()
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("终端日志高亮超过 65536 个词法片段。")
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(lower, base + end),
                kind: .text,
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: identity
            )
        )
    }
}

struct ANSILexingBudget {
    let deadline: ContinuousClock.Instant
    private var remaining: Int

    /// 业务作用：物理行回看、序列匹配与样式生成共享一个有限工作量。
    /// 参数说明:
    /// - deadline: 本次固定快照任务的共同截止。
    /// - maximumSteps: 当前模式全部标记匹配和序列处理共用的扫描额度。
    /// 返回：独立的有限解析预算。
    init(deadline: ContinuousClock.Instant, maximumSteps: Int = 4_194_304) {
        self.deadline = deadline
        remaining = maximumSteps
    }

    /// 业务作用：有界读取与参数解释都计入同一预算，长序列不能绕过取消检查。
    /// 参数说明: 无。
    /// 返回：剩余额度有效时继续，否则整体拒绝。
    mutating func consume() throws {
        guard remaining > 0 else {
            throw NateError.message("词法高亮超过共同扫描预算。")
        }
        remaining -= 1
        if remaining & 255 == 0 {
            try check()
        }
    }

    /// 业务作用：入口与发布之前复验真实取消和所属任务截止。
    /// 参数说明: 无。
    /// 返回：仍有效时继续，失效时不得返回部分样式。
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("词法高亮超过共同截止。")
        }
    }
}
