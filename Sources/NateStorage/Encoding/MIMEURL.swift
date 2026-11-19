import Foundation
import NateCore

extension MIMECodec {
    static let hexAlphabet = Array("0123456789ABCDEF".utf8)

    /// 业务作用：按明确 URL 字节规则转义，逐行模式仅保留实际 CR 与 LF。
    /// 参数说明:
    /// - bytes: 原 UTF-8 或用户明确提供的任意字节。
    /// - operation: RFC 3986、RFC 1738、扩展或全字节规则。
    /// - budget: 同一操作共用的执行预算。
    /// 返回：完整转义文本；百分号与 NUL 均按原字节处理。
    static func encodeURL(_ bytes: [UInt8], operation: MIMEOperation, budget: MIMEBudget) throws -> [UInt8] {
        let byLine = [.urlEncodeRFC1738ByLine, .urlEncodeExtendedByLine, .urlEncodeFullByLine].contains(
            operation
        )
        let full = operation == .urlEncodeFull || operation == .urlEncodeFullByLine
        let reserved = Set("<>\"#%{}|\\^~[]`;/?:@=& ".utf8)
        let extended = Set("!*'()+$,".utf8)
        let rfc1738 = operation == .urlEncodeRFC1738 || operation == .urlEncodeRFC1738ByLine
        var output: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            if index & 4095 == 0 {
                try budget.check(output: output.count)
            }
            let unreserved =
                (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
            let encode =
                operation == .urlEncode
                ? !unreserved
                : full || !(33...126).contains(byte) || reserved.contains(byte)
                    || !rfc1738 && extended.contains(byte)
            if byLine && (byte == 13 || byte == 10) || !encode {
                output.append(byte)
            }
            else {
                output.append(37)
                output.append(hexAlphabet[Int(byte >> 4)])
                output.append(hexAlphabet[Int(byte & 15)])
            }
        }
        try budget.check(output: output.count)
        return output
    }

    /// 业务作用：只展开一次完整百分号三元组，字面加号保持为 Base64 与 URL 原字符。
    /// 参数说明:
    /// - bytes: 原始百分号传输字节。
    /// - budget: 全部解码阶段共用的执行预算。
    /// 返回：完整原字节；残缺或非法转义失败，不递归解码新产生的百分号。
    static func decodeURL(_ bytes: [UInt8], budget: MIMEBudget) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0, nextCheck = 0
        while index < bytes.count {
            if index >= nextCheck {
                try budget.check(output: output.count)
                nextCheck = index + 4096
            }
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                    let low = hexValue(bytes[index + 2])
                else {
                    throw NateError.message("URL 百分号转义必须包含两个十六进制数字。")
                }
                output.append(high << 4 | low)
                index += 3
            }
            else {
                output.append(bytes[index])
                index += 1
            }
        }
        try budget.check(output: output.count)
        return output
    }

    /// 业务作用：按 ASCII 数字验证传输转义，Unicode 相似字符不取得编码意义。
    /// 参数说明:
    /// - byte: 一个原字节。
    /// 返回：合法十六进制半字节；其它为空。
    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
