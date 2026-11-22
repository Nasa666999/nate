import Foundation
import NateCore

extension BatchScanner {
    /// 业务作用：内部命令先处理文本命令和 SET 赋值资格，再定位后续外部命令。
    /// 参数说明: 无。
    /// 返回：本词采用内部命令样式，命令与赋值状态按实际关键字推进。
    mutating func keyword() throws {
        if try equals("echo") || equals("goto") || equals("prompt") {
            state.processing = false
        }
        if try equals("set") {
            state.processing = false
            state.unassigned = true
        }
        if try equals("errorlevel") || equals("exist") {
            command = offset
            command = try skippedSpace(command)
            command = try skippedNonSpace(command)
            command = try skippedSpace(command)
        }
        else if try equals("call") || equals("do") || equals("loadhigh") || equals("lh") {
            command = offset
            command = try skippedSpace(command)
            if byte(command) == 58, try equals("call") {
                state.processing = false
            }
        }
        try colour(until: offset - 1, style: 2)
    }

    /// 业务作用：Batch 特殊紧邻标点命令优先于外部程序，程序路径按真实分隔符逐段识别。
    /// 参数说明: 无。
    /// 返回：完整关键词或外部名称的类别发布到当前行暂存，剩余字节继续处理。
    mutating func ordinaryCommand() throws {
        let length = wordEnd - wordStart
        for count in 2..<max(2, min(7, length)) {
            try budget.consume()
            if try listed(group: 0, count: count),
                try Self.punctuation(word(count))
                    || word(count) == 58
                        && (equals("call", count: count) || equals("echo", count: count)
                            || equals("goto", count: count))
            {
                if try equals("echo", count: count) {
                    state.processing = false
                }
                try colour(until: wordStart + count - 1, style: 2)
                offset = wordStart + count
                return
            }
        }
        let count = try wordLength()
        var style: UInt8 = 0
        if command == wordStart {
            command = wordStart + count
            if try equals("choice") {
                state.processing = false
            }
            if try equals("start") {
                command = try skippedSpace(command)
                if byte(command) == 47 {
                    command = try skippedNonSpace(command)
                    command = try skippedSpace(command)
                }
            }
            if try externalAllowed() {
                style = 5
            }
        }
        try colour(until: wordStart + count - 1, style: style)
        offset = wordStart + count
    }
}
