import Foundation
import NateCore

extension YAMLLexing {
    /// 业务作用：真实 CR/LF/CRLF 决定逐行规则，显示分隔符和源 NUL 不改变原物理范围。
    /// 参数说明: 无。
    /// 返回：整个有界物理输入分类完成，块文本状态继续传给下一连续行。
    mutating func scan() throws {
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count {
                try budget.consume()
                let current = bytes[end]
                end += 1
                if current == 13 {
                    if byte(end) == 10 {
                        end += 1
                    }
                    break
                }
                if current == 10 {
                    break
                }
            }
            try line(start, end)
            try quoteScope(start, end)
            start = end
        }
    }

    /// 业务作用：文档标记、缩进错误和键值边界按固定优先级读取，块文本只由明确父级缩进控制。
    /// 参数说明:
    /// - start: 当前物理行原字节起点。
    /// - end: 含原结束符的末边界。
    /// 返回：当前行分类完成，行结束后只保留明确的块文本父级。
    mutating func line(_ start: Int, _ end: Int) throws {
        var cursor = start
        while cursor < end, byte(cursor) == 32 {
            try budget.consume()
            cursor += 1
        }
        let indent = cursor - start
        guard indent <= 65_535 else {
            throw NateError.message("YAML 块文本缩进超过 65535 个空格，未采用部分状态。")
        }
        if let parent = state.textIndent, indent > parent || emptyCStringLine(start, end) {
            try paint(start, end, style: 7)
            return
        }
        state.textIndent = nil
        if end - start >= 3,
            bytes[start..<start + 3].elementsEqual([45, 45, 45])
                || bytes[start..<start + 3].elementsEqual([46, 46, 46])
        {
            try paint(start, end, style: 6)
            return
        }
        if byte(cursor) == 9 {
            try paint(start, end, style: 8)
            return
        }
        if byte(cursor) == 35 {
            try paint(start, end, style: 1)
            return
        }
        var inQuotes = false
        while cursor < end {
            try budget.consume()
            let current = byte(cursor)
            if current == 39 || current == 34 {
                inQuotes.toggle()
            }
            else if current == 35, Self.white(byte(cursor - 1)), !inQuotes {
                try paint(cursor, end, style: 1)
                return
            }
            else if current == 58, !inQuotes,
                Self.boundarySpace(byte(cursor + 1)) || cursor == end - 1
            {
                try paint(start, cursor, style: 2)
                try paint(cursor, cursor + 1, style: 9)
                try value(cursor + 1, end, indent: indent)
                return
            }
            cursor += 1
        }
    }

    /// 业务作用：基准的空行继承只接受 CR/LF 或原 C 字符串终止位置，纯空格行仍由缩进关系决定。
    /// 参数说明:
    /// - start: 当前物理行起点。
    /// - end: 当前完整末边界。
    /// 返回：首个源 NUL 之前只有 CR/LF 时为真，原字节本身不被截断或移除。
    func emptyCStringLine(_ start: Int, _ end: Int) -> Bool {
        var cursor = start
        while cursor < end, byte(cursor) != 0 {
            if byte(cursor) != 10 && byte(cursor) != 13 {
                return false
            }
            cursor += 1
        }
        return true
    }

    /// 业务作用：固定类别先保留在独立原字节缓冲，词元与状态最后一次性发布。
    /// 参数说明:
    /// - start: 已确认范围的起点。
    /// - end: 已确认范围的末边界。
    /// - style: 原生 YAML 样式编号。
    /// 返回：范围完整取得该类别，所有字节处理计入共同预算。
    mutating func paint(_ start: Int, _ end: Int, style: UInt8) throws {
        for position in start..<end {
            try budget.consume()
            classes[position] = style
        }
    }

    /// 业务作用：源字节与范围之外的零哨兵用于确定有限词法边界，不猜测未提供的正文。
    /// 参数说明:
    /// - offset: 相对当前完整输入的原字节位置。
    /// 返回：范围内原字节，范围之外为零。
    func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    }

    /// 业务作用：值和行内注释采用固定 ASCII 空白范围，Unicode 空格不改变分界含义。
    /// 参数说明:
    /// - byte: 当前候选字节。
    /// 返回：ASCII 空格或 Tab 至 CR 的固定空白时为真。
    static func white(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    /// 业务作用：键后冒号只接受空格、Tab 或真实结束符，值中的冒号不隐式成为新键。
    /// 参数说明:
    /// - byte: 冒号之后的原字节。
    /// 返回：基准允许的键值分隔后继时为真。
    static func boundarySpace(_ byte: UInt8) -> Bool {
        [32, 9, 10, 13].contains(byte)
    }
}
