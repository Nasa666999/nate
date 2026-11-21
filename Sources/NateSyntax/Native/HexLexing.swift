import Foundation

extension PropertyLexing {
    /// 业务作用：各 HEX 物理记录独立解析并沿用当前模式资源，不执行烧录、地址映射或数据写入。
    /// 参数说明:
    /// - start: 当前完整物理记录起点。
    /// - end: 包含真实结束符的记录末边界。
    /// 返回：完整字段进入有界词元，记录或资源超限时由入口舍弃整次呈现。
    mutating func hexLine(_ start: Int, _ end: Int) throws {
        var record = HexRecord(
            bytes: Array(bytes[start..<end]),
            mode: mode,
            budget: budget
        )
        try record.scan()
        budget = record.budget
        for field in record.fields {
            try budget.consume()
            try emit(start + field.range.lower, start + field.range.upper, style: field.style)
        }
    }
}
