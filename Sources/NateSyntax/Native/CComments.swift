import Foundation
import NateCore

extension CLexing {
    /// 业务作用：普通与文档注释保持独立身份，均不能贡献主代码块标点。
    /// 参数说明: 无。
    /// 返回：当前注释所用的确定样式。
    var commentStyle: String {
        state.documentation ? "documentation" : "comment"
    }

    /// 业务作用：逐字节传播注释，只有实际相邻的星号与斜线才能解除块注释。
    /// 参数说明: 无。
    /// 返回：推进完整原字节范围；普通换行结束行注释，块注释继续持有自己的边界。
    mutating func commentByte() throws {
        if state.xmlTerminator {
            // 名称终止字节已经在原状态中判定，不能在同一斜线重新进入另一份 XML 名称。
            state.xmlTerminator = false
        }
        else {
            if try documentationCommand() {
                return
            }
            if try documentationXML() {
                return
            }
        }
        let ending = newlineWidth(at: cursor)
        if ending > 0 {
            try emit(cursor, cursor + ending, kind: .comment, style: commentStyle)
            endLogicalLine()
            cursor += ending
            return
        }
        let byte = bytes[cursor]
        try emit(cursor, cursor + 1, kind: .comment, style: commentStyle)
        cursor += 1
        if state.blockComment {
            if state.blockStar && byte == 47 {
                state.blockComment = false
                state.blockStar = false
                state.documentation = false
            }
            else {
                state.blockStar = byte == 42
            }
        }
    }

    /// 业务作用：只在明确的文档命令位置使用官方命令集合，普通邮件地址和代码注释不被误标。
    /// 参数说明: 无。
    /// 返回：完整消费文档命令时为真，其它情况保留原字节供普通注释处理。
    mutating func documentationCommand() throws -> Bool {
        guard state.documentation, [64, 92].contains(bytes[cursor]),
            cursor + 1 < bytes.count, ![9, 10, 11, 12, 13, 32].contains(bytes[cursor + 1])
        else {
            return false
        }
        let previous: UInt8 = cursor > 0 ? bytes[cursor - 1] : 32
        guard
            [9, 10, 11, 12, 13, 32, 42].contains(previous)
                || state.lineComment && [47, 33].contains(previous)
        else {
            return false
        }
        let start = cursor
        var end = cursor + 1
        var bracket = false
        while end < bytes.count {
            let byte = bytes[end]
            let alphabetic = byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
            guard
                alphabetic || [36, 64, 92, 38, 60, 62, 35, 123, 125, 91, 93].contains(byte)
                    || bracket && [44, 46].contains(byte)
            else {
                break
            }
            try budget.consume()
            if byte == 91 || byte == 123 {
                bracket = true
            }
            end += 1
            if byte == 62 {
                break
            }
        }
        guard end > start + 1 else {
            return false
        }
        let name = String(decoding: bytes[(start + 1)..<end], as: UTF8.self)
        let complete = end == bytes.count || [0, 9, 10, 11, 12, 13, 32].contains(bytes[end])
        let valid =
            complete
            && (documentationKeywords.contains(name)
                || documentationKeywords.contains(String(decoding: bytes[start..<end], as: UTF8.self)))
        try emit(start, end, kind: .comment, style: valid ? "documentationKeyword" : "documentationInvalid")
        // 命令文字已经隔开前面的星号，迟到的斜线不能再消费旧的块注释结束候选。
        state.blockStar = false
        cursor = end
        return true
    }
}
