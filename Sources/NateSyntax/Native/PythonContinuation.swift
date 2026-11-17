import Foundation
import NateCore

enum PythonContinuation {
    /// 业务作用：在固定快照中确认单引号续行区域的最终样式，后续未闭合不能只影响最后一行。
    /// 参数说明:
    /// - snapshot: 与当前词法传播相同的不可变正文。
    /// - offset: 已消费反斜杠和行尾之后的原始字节边界。
    /// - literal: 当前单引号字面类型。
    /// - deadline: 所属扫描器的完整分析截止时刻。
    /// 返回：区域将被标为未闭合时为真；关闭引号或插值起始会完成当前有效片段，超限不猜测结果。
    static func invalid(
        snapshot: DocumentSnapshot,
        from offset: Int,
        literal: PythonLiteral,
        deadline: ContinuousClock.Instant
    ) throws -> Bool {
        var line = snapshot.text.lineNumber(at: offset)
        var consumed = 0
        while line < snapshot.text.lineCount {
            try check(deadline)
            let range = snapshot.text.lineRange(line)
            guard range.count <= 1_048_576, consumed <= 67_108_864 - range.count else {
                throw NateError.message("Python 高亮暂停：续行确认超过单行或 64 MB 正文预算。")
            }
            consumed += range.count
            let bytes = Array(snapshot.text.text(in: range).utf8)
            var cursor = max(0, offset - range.lower)
            while cursor < bytes.count {
                if cursor & 16_383 == 0 {
                    try check(deadline)
                }
                let byte = bytes[cursor]
                if byte == 92 {
                    if cursor + 1 == bytes.count {
                        return false
                    }
                    if literal.formatted && bytes[cursor + 1] == 123 {
                        cursor += 1
                    }
                    else {
                        cursor += 2
                        if bytes[cursor - 1] == 13 && cursor < bytes.count && bytes[cursor] == 10 {
                            cursor += 1
                        }
                    }
                }
                else if byte == literal.quote {
                    return false
                }
                else if literal.formatted && byte == 123 {
                    if cursor + 1 < bytes.count && bytes[cursor + 1] == 123 {
                        cursor += 2
                    }
                    else {
                        return false
                    }
                }
                else if byte == 10 || byte == 13 {
                    return true
                }
                else {
                    cursor += 1
                }
            }
            line += 1
        }
        return true
    }

    /// 业务作用：后续字面证据同样服从实际取消和所属任务预算，不能无限阻塞旧快照的解析位。
    /// 参数说明:
    /// - deadline: 当前扫描流程的截止时刻。
    /// 返回：仍有资格时继续，否则丢弃未确认的续行样式。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("Python 高亮暂停：续行确认超过当前分析时间预算。")
        }
    }
}
