import NateCore

enum FortranFixedIndentationSource: Equatable {
    case comment
    case initial
    case continuation
    case unconfirmedContinuation
    case unconfirmed

    /// 业务作用：固定格式的结构输入先确认真实记录栏位，制表宽度和同行词语不能替代原第六列证据。
    /// 参数说明:
    /// - bytes: 当前物理行前至多七十二个原字节。
    /// 返回：真实注释、新语句、续接或需要保留原缩进的未确认记录。
    static func classify(_ bytes: ArraySlice<UInt8>) -> FortranFixedIndentationSource {
        let columns = bytes.prefix(72)
        if let first = columns.first, first == 67 || first == 99 || first == 42 {
            return .comment
        }
        guard
            let from = columns.firstIndex(where: {
                !FortranCharacters.space(UInt32($0))
            })
        else {
            return .comment
        }
        if columns[from] == 33, from - columns.startIndex != 5 {
            return .comment
        }
        guard columns.count >= 6,
            columns.prefix(5).allSatisfy({
                $0 == 32
            })
        else {
            return .unconfirmed
        }
        let mark = columns[columns.startIndex + 5]
        if mark == 32 {
            return .initial
        }
        // 第六列的惊叹号具备续接含义，但原生样式隐藏了该行正文，缩进必须保留原前缀。
        if mark == 33 {
            return .unconfirmedContinuation
        }
        // 分号属于续接栏；控制字节、非 ASCII 和零栏位保持原记录。
        return (33...126).contains(mark) && mark != 48 ? .continuation : .unconfirmed
    }

    /// 业务作用：用下一条真实非注释记录确认当前固定格式语句是否继续，避免按不完整声明改变后继结构。
    /// 参数说明:
    /// - line: 正在确认的实际物理行号。
    /// - text: 本次输入固定的完整正文。
    /// - check: 全部目标共同拥有的继续资格。
    /// 返回：下一条有效记录含续接标记时为真，文件尾或新语句时为假。
    static func follows(_ line: Int, text: PieceTree, check: () throws -> Void) throws -> Bool {
        var visited = 0
        for next in (line + 1)..<text.lineCount {
            try check()
            let row = text.lineRange(next, includeEnding: false)
            let length = min(72, row.count)
            guard visited <= 64 * 1_048_576 - length, next < 1_048_576 else {
                throw NateError.message("Fortran 固定格式续接前瞻超过原文或行数预算。")
            }
            visited += length
            switch classify(text.bytes(in: ByteRange(row.lower, row.lower + length))[...]) {
            case .comment:
                continue
            case .continuation, .unconfirmedContinuation:
                return true
            case .initial, .unconfirmed:
                return false
            }
        }
        return false
    }
}
