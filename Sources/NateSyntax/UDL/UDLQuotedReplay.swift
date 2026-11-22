import Foundation
import NateCore

struct UDLQuotedReplay {
    let length: Int
    let style: String
    let pop: Bool
    let push: UDLContext?

    /// 业务作用：短语首段遇到前向边界时，保留该动作在短语着色之后执行的原始顺序。
    /// 参数说明:
    /// - bytes: 当前片段的原字节。
    /// - offset: 已确认短语的起点。
    /// - state: 识别短语前的真实上下文。
    /// - nesting: 当前样式允许的嵌套位。
    /// - comments: 保留对应位置的注释规则。
    /// - delimiters: 保留对应位置的分隔符规则。
    /// - definition: 当前固定 UDL。
    /// - budget: 本行扫描共同预算。
    /// 返回：首个前向动作的后继消费与上下文职责；先遇到空白时没有延后动作。
    static func prepare(
        bytes: [UInt8],
        offset: Int,
        state: UDLState,
        nesting: UInt32,
        comments: UDLForwardRules,
        delimiters: UDLForwardRules,
        definition: UDLDefinition,
        budget: UDLScanBudget
    ) throws -> UDLQuotedReplay? {
        var position = offset + 1
        let context = state.contexts.last
        while position < bytes.count {
            try budget.consume()
            if bytes[position] > 0 && bytes[position] < 33 {
                return nil
            }
            if bytes[position] & 0xC0 == 0x80 {
                position += 1
                continue
            }
            if let context,
                let escape = try budget.longest(
                    key: context.ruleKey + ":escape",
                    patterns: context.escapes,
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored
                )
            {
                position = min(bytes.count, position + escape.utf8.count + 1)
                continue
            }
            if let context,
                let end = try budget.longest(
                    key: context.ruleKey + ":end",
                    patterns: context.ends,
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored
                )
            {
                return UDLQuotedReplay(
                    length: end.utf8.count,
                    style: context.style,
                    pop: true,
                    push: nil
                )
            }
            var starts: [(Int, String, UInt32)] = []
            if context == nil {
                starts = [(3, "COMMENTS", 0x100), (0, "LINE COMMENTS", 0x200)]
            }
            for group in 0..<8 {
                starts.append((group * 3, "DELIMITERS\(group + 1)", 1 << group))
            }
            if context != nil {
                starts += [(3, "COMMENTS", 0x100), (0, "LINE COMMENTS", 0x200)]
            }
            for (field, style, mask) in starts where nesting & mask != 0 {
                if style == "LINE COMMENTS", definition.lineCommentPosition != .anywhere {
                    continue
                }
                let rules = style.contains("COMMENT") ? comments : delimiters
                let key =
                    style == "COMMENTS"
                    ? "Comments3" : style == "LINE COMMENTS" ? "Comments0" : "Delimiter\(field / 3)"
                if let opener = try rules.match(
                    field: field,
                    key: key,
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored,
                    budget: budget
                ) {
                    guard state.contexts.count < 128 else {
                        // 前向动作也必须先取得完整上下文容量，不能在短语发布后才发现无法记录开端。
                        throw NateError.message("UDL 短语后继嵌套超过 128 层，样式未发布。")
                    }
                    let comment = style == "COMMENTS"
                    let line = style == "LINE COMMENTS"
                    return UDLQuotedReplay(
                        length: opener.text.utf8.count,
                        style: style,
                        pop: false,
                        push: UDLContext(
                            style: style,
                            ends: rules.patterns(field: comment ? 4 : field + 2, group: opener.group),
                            escapes: comment || line
                                ? [] : rules.patterns(field: field + 1, group: opener.group),
                            lineOnly: line,
                            continues: line ? rules.patterns(field: 1, group: opener.group) : [],
                            ruleGroup: opener.group
                        )
                    )
                }
            }
            if nesting & 0x1000000 != 0,
                let op = try budget.longest(
                    key: "Operators1",
                    patterns: definition.lists["Operators1"] ?? [],
                    bytes: bytes,
                    offset: position,
                    ignoreCase: definition.caseIgnored
                )
            {
                return UDLQuotedReplay(
                    length: op.utf8.count,
                    style: "OPERATORS",
                    pop: false,
                    push: nil
                )
            }
            position += 1
        }
        return nil
    }
}
