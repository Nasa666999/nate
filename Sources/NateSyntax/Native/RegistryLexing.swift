import Foundation
import NateCore

struct RegistryLexing {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let styles: [String: LanguageTokenStyle]
    var state: RegistryLexicalState
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var tokens: [SyntaxToken] = []

    /// 业务作用：固定 Registry 来源与逐行检查点，完整确认值、键和字面后才发布下一行状态。
    /// 参数说明:
    /// - text: 当前完整物理行，包含真实结束符。
    /// - base: 当前物理行在原始正文中的 UTF-8 起点。
    /// - snapshot: 用于核对来源及有限向前证据的完整不可变正文。
    /// - styles: 当前语言资源的固定样式。
    /// - deadline: 所属完整语法任务的共同截止。
    /// - state: 前一完整行的检查点，失败时只更新诊断。
    /// 返回：完整且有界的原字节样式；来源、顺序、资源、取消或容量不足时不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        styles: [String: LanguageTokenStyle]?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            let budget = ANSILexingBudget(deadline: deadline, maximumSteps: 8_388_608)
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.registry.nextOffset == nil || state.registry.nextOffset == base,
                let styles, styles.count <= 256,
                (0...12).allSatisfy({
                    styles[String($0)] != nil
                })
            else {
                throw NateError.message("Registry 高亮缺少完整样式，或行范围与检查点不一致。")
            }
            let range = ByteRange(base, base + text.utf8.count)
            if let documentID = state.registry.documentID {
                // 来自其它正文、修订或失去来源证明的检查点不能解释当前字符串与键路径边界。
                guard let snapshot, snapshot.id == documentID,
                    snapshot.revision == state.registry.revision
                else {
                    throw NateError.message("Registry 检查点与当前文档修订不一致。")
                }
            }
            if let snapshot {
                let tree = snapshot.text
                // 需要整行证据才能判定值名后的等号及键路径末端，分段不能猜测未读取的后缀。
                guard range.upper <= tree.byteCount,
                    tree.isBoundary(range.lower), tree.isBoundary(range.upper),
                    (range.lower == 0 || tree.byte(at: range.lower - 1) == 10
                        || tree.byte(at: range.lower - 1) == 13 && tree.byte(at: range.lower) != 10),
                    (range.upper == tree.byteCount || tree.byte(at: range.upper - 1) == 10
                        || tree.byte(at: range.upper - 1) == 13 && tree.byte(at: range.upper) != 10),
                    tree.bytes(in: range).elementsEqual(text.utf8)
                else {
                    throw NateError.message("Registry 高亮来源不是固定快照中的完整物理行。")
                }
            }
            var scanner = RegistryLexing(
                bytes: Array(text.utf8),
                base: base,
                snapshot: snapshot,
                styles: styles,
                state: state.registry,
                budget: budget
            )
            try scanner.scan()
            try scanner.budget.check()
            scanner.state.nextOffset = range.upper
            if let snapshot {
                scanner.state.documentID = snapshot.id
                scanner.state.revision = snapshot.revision
            }
            scanner.state.tail =
                scanner.bytes.count >= 3
                ? Array(scanner.bytes.suffix(3)) : Array((scanner.state.tail + scanner.bytes).suffix(3))
            // 所有呈现片段先完成再发布检查点，超限不能留下半个转义、GUID 或跨行字符串。
            try scanner.budget.check()
            state.registry = scanner.state
            return scanner.tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：采用 Registry 独立状态机保留键、字符串、转义和十六进制上下文，字面内容不执行。
    /// 参数说明: 无。
    /// 返回：完整推进输入并生成有限片段；失败由入口舍弃全部临时状态。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            if cursor == 0 || byte(at: cursor - 1) == 10
                || byte(at: cursor - 1) == 13 && current != 10
            {
                state.highlight = byte(at: cursor - 3) == 92
            }
            switch state.style {
            case 1:
                if atLineEnd {
                    try setStyle(0)
                }
            case 2, 3:
                try stringStep()
            case 11:
                forward()
                try setStyle(3)
                if current == 34 {
                    forward()
                    try setStyle(0)
                }
            case 5:
                if current == 58 {
                    try setStyle(0)
                    state.afterEqualSign = false
                }
            case 4, 12:
                try setStyle(0)
            case 6, 7:
                if current == 93, try keyPathEnd(at: cursor) {
                    forward()
                    try setStyle(0)
                }
                else if current == 123, try guid(at: cursor) {
                    state.beforeGUID = state.style
                    try setStyle(9)
                }
            case 8:
                if current == 34 {
                    try setStyle(state.beforeEscape)
                    forward()
                    try setStyle(0)
                }
                else if current == 92 {
                    forward()
                }
                else {
                    try setStyle(state.beforeEscape)
                    state.beforeEscape = 0
                }
            case 9, 10:
                if current == 125 {
                    forward()
                    try setStyle(state.beforeGUID)
                    state.beforeGUID = 0
                }
                if current == 34, [2, 3].contains(state.style) {
                    forward()
                    try setStyle(0)
                }
                else if current == 93, [6, 7].contains(state.style), try keyPathEnd(at: cursor) {
                    forward()
                    try setStyle(0)
                }
                else if current == 92, [2, 3].contains(state.style) {
                    state.beforeEscape = state.style
                    try setStyle(8)
                    forward()
                }
            default:
                break
            }
            if state.style == 0 {
                try enter()
            }
            forward()
        }
        try emit(until: bytes.count, style: state.style)
    }

    /// 业务作用：普通值和名称字符串采用各自身份，GUID、参数与转义只在实际字符串上下文进入。
    /// 参数说明: 无。
    /// 返回：推进当前必要字节并维持完整状态，不让转义后的标点变成主结构。
    mutating func stringStep() throws {
        if current == 34 {
            forward()
            try setStyle(0)
        }
        else if current == 92 {
            state.beforeEscape = state.style
            try setStyle(8)
            forward()
        }
        else if current == 123, try guid(at: cursor) {
            state.beforeGUID = state.style
            try setStyle(10)
        }
        if state.style == 3, current == 37,
            Self.digit(byte(at: cursor + 1)) || byte(at: cursor + 1) == 42
        {
            try setStyle(11)
        }
    }

    /// 业务作用：仅在中性上下文确认新类别，等号后的类型候选与十六进制权限分别传播。
    /// 参数说明: 无。
    /// 返回：进入当前字节的完整类别；注释或字符串中的外观不被重新解释。
    mutating func enter() throws {
        if current == 59 {
            try setStyle(1)
        }
        else if current == 34 {
            try setStyle(try valueName(at: cursor) ? 2 : 3)
        }
        else if current == 91 {
            try setStyle(try nextNonWhitespace(at: cursor, is: 45) ? 7 : 6)
        }
        else if current == 61 {
            state.afterEqualSign = true
            state.highlight = true
        }
        else if state.afterEqualSign {
            if Self.alpha(current), !Self.alpha(byte(at: cursor - 1)), try valueType(at: cursor) {
                try setStyle(5)
            }
        }
        else if Self.hex(current), state.highlight {
            try setStyle(4)
        }
        if current == 64 {
            state.highlight = true
        }
        if "-,.=:\\@()".utf8.contains(current), state.highlight {
            try setStyle(12)
        }
    }

    /// 业务作用：按当前标量推进原始 UTF-8，转义不能把多字节字符拆成不同样式或非法端点。
    /// 参数说明: 无。
    /// 返回：当前位置越过一个完整标量；末尾哨兵只推进内部游标，不生成源范围。
    mutating func forward() {
        let byte = current
        cursor += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
    }

    /// 业务作用：状态切换先封存此前完整源范围，当前字符由新身份持有。
    /// 参数说明:
    /// - style: 新的固定资源样式编号。
    /// 返回：此前片段进入有限结果，状态仅在整轮完成后对外发布。
    mutating func setStyle(_ style: Int) throws {
        try emit(until: min(cursor, bytes.count), style: state.style)
        state.style = style
    }

    /// 业务作用：完整原字节范围与资源属性一同进入有限列表，连续同类呈现不重复占用容量。
    /// 参数说明:
    /// - end: 当前源范围末边界。
    /// - style: 当前范围所属的固定编号。
    /// 返回：合法完整片段追加或合并；缺少样式、非法端点或超量时拒绝整行。
    mutating func emit(until end: Int, style: Int) throws {
        guard end > segment else {
            return
        }
        guard let attributes = styles[String(style)] else {
            throw NateError.message("Registry 高亮缺少当前样式。")
        }
        let identity = "registry:" + String(style)
        let lower: Int
        if let previous = tokens.last, previous.lexicalStyle == identity,
            previous.range.upper == base + segment
        {
            lower = previous.range.lower
            tokens.removeLast()
        }
        else {
            lower = base + segment
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("Registry 高亮超过 65536 个词法片段。")
        }
        let kinds: [SyntaxKind] = [
            .text, .comment, .keyword, .string, .number, .keyword, .heading, .heading,
            .string, .heading, .string, .string, .punctuation,
        ]
        tokens.append(
            SyntaxToken(
                range: ByteRange(lower, base + end),
                kind: kinds[style],
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: identity
            )
        )
        segment = end
    }
}
