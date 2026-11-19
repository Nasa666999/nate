import Foundation
import NateCore

extension MIMECodec {
    /// 业务作用：生成不超过七十六列的 Quoted-Printable，保留原字节与硬 CRLF。
    /// 参数说明:
    /// - bytes: 包含原始换行、空白与 NUL 的完整字节。
    /// - budget: 同一操作的执行预算。
    /// 返回：尾随空白、孤立 CR 或 LF 均显式转义，软折行不改变解码后的字节。
    static func encodeQuotedPrintable(_ bytes: [UInt8], budget: MIMEBudget) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0, column = 0, nextCheck = 0
        while index < bytes.count {
            if index >= nextCheck {
                try budget.check(output: output.count)
                nextCheck = index + 4096
            }
            let byte = bytes[index]
            if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                output.append(contentsOf: [13, 10])
                column = 0
                index += 2
                continue
            }
            let trailing = index + 1 == bytes.count || bytes[index + 1] == 13 || bytes[index + 1] == 10
            let plain =
                (33...60).contains(byte) || (62...126).contains(byte)
                || (byte == 9 || byte == 32) && !trailing
            let size = plain ? 1 : 3
            if column + size > 75 {
                output.append(contentsOf: [61, 13, 10])
                column = 0
            }
            if plain {
                output.append(byte)
            }
            else {
                output.append(61)
                output.append(hexAlphabet[Int(byte >> 4)])
                output.append(hexAlphabet[Int(byte & 15)])
            }
            column += size
            index += 1
        }
        try budget.check(output: output.count)
        return output
    }

    /// 业务作用：严格展开完整 Quoted-Printable，软 CRLF 与软 LF 只承担传输折行。
    /// 参数说明:
    /// - bytes: ASCII 传输原文；硬换行的实际字节保持不变。
    /// - budget: 整次操作共用的执行预算。
    /// 返回：完整字节；非法等号、非 ASCII 或裸控制字节失败，NUL 必须由 =00 表达。
    static func decodeQuotedPrintable(_ bytes: [UInt8], budget: MIMEBudget) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0, nextCheck = 0
        while index < bytes.count {
            if index >= nextCheck {
                try budget.check(output: output.count)
                nextCheck = index + 4096
            }
            let byte = bytes[index]
            if byte == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                guard index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                    let low = hexValue(bytes[index + 2])
                else {
                    throw NateError.message("Quoted-Printable 等号后缺少完整十六进制字节或软换行。")
                }
                output.append(high << 4 | low)
                index += 3
            }
            else {
                guard (33...126).contains(byte) || [9, 10, 13, 32].contains(byte) else {
                    throw NateError.message("Quoted-Printable 包含未转义的非 ASCII 或控制字节。")
                }
                // 传输协议规定行尾裸空白不可作为数据证据；原空白由显式 =20 或 =09 保留。
                if byte == 9 || byte == 32 {
                    var end = index
                    while end < bytes.count, bytes[end] == 9 || bytes[end] == 32 {
                        if end & 4095 == 0 {
                            try budget.check(output: output.count)
                        }
                        end += 1
                    }
                    if end == bytes.count || bytes[end] == 10 || bytes[end] == 13 {
                        index = end
                        continue
                    }
                    output.append(contentsOf: bytes[index..<end])
                    index = end
                }
                else {
                    output.append(byte)
                    index += 1
                }
            }
        }
        try budget.check(output: output.count)
        return output
    }
}
