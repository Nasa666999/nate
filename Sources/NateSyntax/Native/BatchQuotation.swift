import Foundation
import NateCore

extension BatchScanner {
    /// 业务作用：连续 caret 的奇偶性决定当前操作符或引用是否实际转义。
    /// 参数说明:
    /// - position: 本物理行中的待解释位置。
    /// 返回：紧邻的 caret 数为奇数时为真。
    mutating func escaped(at position: Int) throws -> Bool {
        var cursor = position, result = false
        while cursor > 0 && byte(cursor - 1) == 94 {
            try budget.consume()
            result.toggle()
            cursor -= 1
        }
        return result
    }

    /// 业务作用：Batch 单双引号各自按未转义开闭传播，操作符资格只取实际物理行前缀。
    /// 参数说明:
    /// - end: 本次判断之前的实际原字节范围末端。
    /// 返回：任一引用通道尚未闭合时为真；重复前缀读取仍计入共同预算。
    mutating func quoted(until end: Int) throws -> Bool {
        guard end >= 0, end <= bytes.count else {
            throw NateError.invalidRange
        }
        var single = false, double = false, escape = false
        for index in 0..<end {
            try budget.consume()
            let current = byte(index)
            if !escape {
                if current == 34 {
                    double.toggle()
                }
                else if current == 39 {
                    single.toggle()
                }
            }
            escape = current == 94 ? !escape : false
        }
        return single || double
    }

    /// 业务作用：文本命令只在未转义、未引用的物理行尾 caret 后继续关闭关键字检查。
    /// 参数说明: 无。
    /// 返回：存在合格续行标记时为真，空行和普通物理行均为假。
    mutating func continuation() throws -> Bool {
        guard bytes.count > 1, bytes != [13, 10] else {
            return false
        }
        let position =
            bytes.count > 2 && bytes[bytes.count - 2] == 13
            ? bytes.count - 3 : bytes.count - 2
        return try byte(position) == 94 && !escaped(at: position) && !quoted(until: position)
    }
}
