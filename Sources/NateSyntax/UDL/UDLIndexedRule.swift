import Foundation

struct UDLIndexedRule {
    let field: Int
    let body: String

    /// 业务作用：编号只读取两个 ASCII 原字节，正负号及字形组合不能改变字段身份或吞去正文标记。
    /// 参数说明:
    /// - word: 当前保留候选组语法的完整字段。
    /// - maximum: 当前规则组允许的最大字段编号。
    /// 返回：合法编号及完整原始内容；空内容是有效占位，前缀或编号范围不合法时为空。
    static func parse(_ word: String, maximum: Int) -> UDLIndexedRule? {
        let bytes = word.utf8
        guard bytes.count >= 2, let first = bytes.first, let second = bytes.dropFirst().first,
            (48...57).contains(first), (48...57).contains(second)
        else {
            return nil
        }
        let field = Int(first - 48) * 10 + Int(second - 48)
        guard field <= maximum else {
            return nil
        }
        return UDLIndexedRule(
            field: field,
            body: String(decoding: bytes.dropFirst(2), as: UTF8.self)
        )
    }
}
