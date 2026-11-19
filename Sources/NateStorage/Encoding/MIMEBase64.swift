import Foundation
import NateCore

extension MIMECodec {
    static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// 业务作用：按完整字节编码 Base64，逐行模式保留每个实际 CR、LF 和 CRLF。
    /// 参数说明:
    /// - bytes: 原字节。
    /// - operation: 填充、六十四列 LF 折行或逐行规则。
    /// - budget: 整次操作共用的容量与取消预算。
    /// 返回：完整 ASCII 传输文本，不为末尾额外添加换行。
    static func encodeBase64(_ bytes: [UInt8], operation: MIMEOperation, budget: MIMEBudget) throws -> [UInt8]
    {
        var output: [UInt8] = []
        var index = 0, column = 0, nextCheck = 0
        let byLine = operation == .base64EncodeByLine
        let padded = operation == .base64Encode || operation == .base64EncodeWrapped
        while index < bytes.count {
            if index >= nextCheck {
                try budget.check(output: output.count)
                nextCheck = index + 4096
            }
            if byLine, bytes[index] == 13 || bytes[index] == 10 {
                output.append(bytes[index])
                index += 1
                continue
            }
            var value: UInt32 = 0, count = 0
            while count < 3, index < bytes.count {
                if byLine, bytes[index] == 13 || bytes[index] == 10 {
                    break
                }
                value |= UInt32(bytes[index]) << (16 - 8 * count)
                count += 1
                index += 1
            }
            for position in 0..<(padded ? 4 : count + 1) {
                if operation == .base64EncodeWrapped, column == 64 {
                    output.append(10)
                    column = 0
                }
                output.append(
                    position <= count ? base64Alphabet[Int((value >> (18 - 6 * position)) & 63)] : 61
                )
                column += 1
            }
        }
        try budget.check(output: output.count)
        return output
    }

    /// 业务作用：仅接受完整有效的 Base64 片段，显式分段模式才保留原分隔符。
    /// 参数说明:
    /// - bytes: ASCII 传输原文。
    /// - operation: 严格单段、按非字母分段或按四种 ASCII 空白分行。
    /// - budget: 整次操作的执行预算。
    /// 返回：完整原始字节；残缺单位、非法填充和非零尾位失败。
    static func decodeBase64(_ bytes: [UInt8], operation: MIMEOperation, budget: MIMEBudget) throws -> [UInt8]
    {
        var output: [UInt8] = []
        var group: [UInt8] = []
        var padding = 0, ended = false
        for (index, byte) in bytes.enumerated() {
            if index & 4095 == 0 {
                try budget.check(output: output.count)
            }
            let whitespace = [9, 10, 13, 32].contains(byte)
            let value = base64Value(byte)
            let separator =
                operation == .base64DecodeSegments && value == nil && byte != 61
                || operation == .base64DecodeByLine && whitespace
            if separator {
                try finishBase64(group, padding: padding, output: &output)
                group.removeAll(keepingCapacity: true)
                padding = 0
                ended = false
                output.append(byte)
            }
            else if whitespace {
                continue
            }
            else if byte == 61 {
                guard !ended, group.count == 2 || group.count == 3, padding < 2 else {
                    throw NateError.message("Base64 填充位置无效。")
                }
                padding += 1
                guard group.count + padding <= 4 else {
                    throw NateError.message("Base64 填充过多。")
                }
                if group.count + padding == 4 {
                    try finishBase64(group, padding: padding, output: &output)
                    group.removeAll(keepingCapacity: true)
                    padding = 0
                    ended = true
                }
            }
            else if let value {
                guard !ended, padding == 0 else {
                    throw NateError.message("Base64 填充后仍有数据。")
                }
                group.append(value)
                if group.count == 4 {
                    try finishBase64(group, padding: 0, output: &output)
                    group.removeAll(keepingCapacity: true)
                }
            }
            else {
                throw NateError.message("Base64 包含非法字符。")
            }
        }
        try finishBase64(group, padding: padding, output: &output)
        try budget.check(output: output.count)
        return output
    }

    /// 业务作用：完整验证末组填充与未使用尾位，避免不同传输文本被静默解释为相同原字节。
    /// 参数说明:
    /// - group: 零至四个六位值。
    /// - padding: 末组实际等号数。
    /// - output: 尚未发布的完整字节累积。
    /// 返回：合法完整组或合法未填充末组追加原字节；其它形态失败。
    static func finishBase64(_ group: [UInt8], padding: Int, output: inout [UInt8]) throws {
        guard group.count != 1, padding == 0 || group.count + padding == 4,
            group.count != 2 || group[1] & 15 == 0,
            group.count != 3 || group[2] & 3 == 0
        else {
            throw NateError.message("Base64 末组、填充或尾位无效。")
        }
        guard group.count >= 2 else {
            return
        }
        output.append(group[0] << 2 | group[1] >> 4)
        if group.count >= 3 {
            output.append(group[1] << 4 | group[2] >> 2)
        }
        if group.count == 4 {
            output.append(group[2] << 6 | group[3])
        }
    }

    /// 业务作用：只识别标准 ASCII Base64 字母，不把高位字节映射成另一合法字符。
    /// 参数说明:
    /// - byte: 一个原传输字节。
    /// 返回：标准六位值；非法字符为空。
    static func base64Value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: return byte - 65
        case 97...122: return byte - 71
        case 48...57: return byte + 4
        case 43: return 62
        case 47: return 63
        default: return nil
        }
    }
}
