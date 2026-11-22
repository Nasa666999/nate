import Foundation
import NateCore

extension MSSQLScanner {
    /// 业务作用：名称后尚未定类的空白按下一真实词元确认身份，跨行证据在同源状态中有界复用。
    /// 参数说明: 无。
    /// 返回：后继引用、块注释或变量前采用默认类，其它后继保留类型优先空白；证据超量整体拒绝。
    mutating func preferredStyle() throws -> UInt8 {
        let position = base + cursor
        if let end = state.preferredEnd, position < end {
            return state.preferredStyle
        }
        let limit = snapshot?.text.byteCount ?? base + bytes.count
        var end = position
        var style: UInt8 = 15
        while end < limit {
            try budget.consume()
            // 未决空白不能借跨越许多短行而无界回看后继，否则旧颜色会先于完整证据发布。
            guard end - position < 1_048_576 else {
                throw NateError.message("T-SQL 未决空白后继超过 1 MiB，未发布部分样式。")
            }
            let byte = snapshot?.text.byte(at: end) ?? bytes[end - base]
            let next: UInt8?
            if let snapshot {
                next = snapshot.text.byte(at: end + 1)
            }
            else {
                next = end + 1 < limit ? bytes[end + 1 - base] : nil
            }
            if byte == 39 || byte == 34 || byte == 91 || byte == 64 || byte == 47 && next == 42 {
                style = 0
                break
            }
            if Self.wordStart(byte) || Self.isOperator(byte) {
                break
            }
            end += 1
        }
        state.preferredEnd = end
        state.preferredStyle = style
        return style
    }
}
