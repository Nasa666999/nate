import Foundation

enum UDLPhysicalLine {
    /// 业务作用：行注释只在当前定义明确允许的位置进入，普通代码或 NUL 不能被当作前导空白。
    /// 参数说明:
    /// - position: 当前定义的任意位置、严格行首或前导空白策略。
    /// - atLineStart: 实际消费位置是否仍在物理行起点。
    /// - hasVisible: 本物理行是否已消费非 ASCII 空白的原字节。
    /// 返回：当前开端有进入行注释的资格时为真，不改动词法上下文。
    static func permits(_ position: UDLLineCommentPosition, atLineStart: Bool, hasVisible: Bool) -> Bool {
        switch position {
        case .anywhere: return true
        case .lineStart: return atLineStart
        case .leadingWhitespace: return !hasVisible
        }
    }

    /// 业务作用：实际消费的原文推进物理行证据，长标记、转义和跨片段输入都沿相同 CR/LF 规则。
    /// 参数说明:
    /// - bytes: 本轮真正消费的完整原字节片段，所属扫描已预留其线性工作量。
    /// - state: 仅本次候选扫描使用的行首状态。
    /// 返回：CR 或 LF 重新建立行首；ASCII 控制空白允许前导模式，NUL 与其它原字节视为已有内容。
    static func advance(_ bytes: ArraySlice<UInt8>, state: inout UDLState) {
        for byte in bytes {
            if byte == 13 || byte == 10 {
                state.atLineStart = true
                state.hasVisible = false
            }
            else {
                state.atLineStart = false
                if byte == 0 || byte >= 33 {
                    state.hasVisible = true
                }
            }
        }
    }

    /// 业务作用：续行标记必须紧邻真实结束符，行内相同文字不能逃逸闭合符或无条件延续注释。
    /// 参数说明:
    /// - bytes: 当前完整物理行或明确连续片段。
    /// - offset: 真实 CR 或 LF 之前的位置。
    /// - patterns: 本行注释组的原续行候选。
    /// - ignoreCase: 当前定义的原长度小写比较规则。
    /// - budget: 整份行扫描共用的工作量与截止。
    /// 返回：完整候选恰好结束于行尾时为真，否则为假；资格不足时拒绝本次完整呈现。
    static func continues(
        bytes: [UInt8],
        before offset: Int,
        patterns: [String],
        ignoreCase: Bool,
        budget: UDLScanBudget
    ) throws -> Bool {
        for pattern in patterns {
            try budget.consume()
            let count = pattern.utf8.count
            guard count > 0, count <= offset else {
                continue
            }
            try budget.consume(count)
            let suffix = bytes[(offset - count)..<offset]
            if ignoreCase {
                if String(decoding: suffix, as: UTF8.self).lowercased().utf8.elementsEqual(
                    pattern.lowercased().utf8
                ) {
                    return true
                }
            }
            else if suffix.elementsEqual(pattern.utf8) {
                return true
            }
        }
        return false
    }
}
