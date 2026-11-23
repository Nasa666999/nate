import Foundation
import NateCore

extension AutoItScanner {
    /// 业务作用：续行资格沿固定原字节的真实 CR、LF 和 CRLF 行边界确定，原生 EOF 不伪造末尾换行。
    /// 参数说明: 无。
    /// 返回：完整物理行起点已建立，全部读取计入本轮预算；取消或超量时抛错。
    mutating func prepareLines() throws {
        for index in bytes.indices {
            try budget.consume()
            if bytes[index] == 10
                || bytes[index] == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)
            {
                lineStarts.append(index + 1)
            }
        }
    }

    /// 业务作用：独立行尾动作只发生在真实结束字符或全文 EOF，实际 NUL 不能关闭当前通道。
    /// 参数说明: 无。
    /// 返回：当前完整标量处于原生行尾时为真；读取预算不足时抛错。
    mutating func atLineEnd() throws -> Bool {
        let value = try current()
        if value == 10 {
            return true
        }
        if value == 13 {
            return try next() != 10
        }
        return documentEnd && cursor >= bytes.count
    }

    /// 业务作用：字符串续行保留原生末字节偏移及空白规则，真实 EOF 的最后一个字节不会被补成结束符。
    /// 参数说明: 无。
    /// 返回：原生范围内最后有效非空白字节为下划线时为真；预算不足时拒绝整份扫描。
    mutating func continuation() throws -> Bool {
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            try budget.consume()
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= cursor {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        let line = max(0, lower - 1)
        let start = lineStarts[line]
        var end = (line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count) - 2
        while start < end {
            try budget.consume()
            let value = bytes[end]
            if ![9, 10, 11, 12, 13, 32].contains(value) {
                return value == 95
            }
            end -= 1
        }
        return false
    }
}
