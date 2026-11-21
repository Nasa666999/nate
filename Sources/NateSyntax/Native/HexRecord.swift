import Foundation
import NateCore

struct HexField {
    let range: ByteRange
    let style: Int
}

struct HexRecord {
    let bytes: [UInt8]
    let mode: LineLexicalMode
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var style = 0
    var fields: [HexField] = []

    /// 业务作用：一条 HEX 记录独立决定字段身份，错误长度和校验和仅影响呈现，不改写原始记录。
    /// 参数说明: 无。
    /// 返回：完整、单调且有界的原字节字段；真实行末恢复中性，截断记录不影响下一行。
    mutating func scan() throws {
        let marker: UInt8 = mode == .ihex ? 58 : (mode == .srec ? 83 : 37)
        if bytes.first == marker {
            if mode == .tehex {
                try tektronix()
            }
            else {
                try standard()
            }
            if cursor < bytes.count {
                try setStyle(18)
                while cursor < bytes.count {
                    _ = try advance(1)
                }
            }
        }
        try flush(until: bytes.count)
        try budget.check()
    }

    /// 业务作用：Intel 与 Motorola 记录共享字段推进，但计数字段、地址宽度和校验和位置各自确认。
    /// 参数说明: 无。
    /// 返回：逐字段确认当前记录；任何字段触及真实行末或正文末尾即停止后续解释。
    mutating func standard() throws {
        guard try field(1, count: 1) else {
            return
        }
        if mode == .srec {
            let origin = cursor - 1
            guard try field(addressType(origin) == 10 ? 3 : 2, count: 1) else {
                return
            }
        }
        let countOrigin = cursor - (mode == .srec ? 2 : 1)
        let count = byteCount(countOrigin)
        let required = dataSize(countOrigin) + (mode == .srec ? addressSize(countOrigin) + 1 : 0)
        let correct = count == (try countedBytes(countOrigin)) && count == required
        guard try field(correct ? 4 : 5, count: 2) else {
            return
        }
        let addressOrigin = cursor - (mode == .srec ? 4 : 3)
        guard try field(addressType(addressOrigin), count: addressSize(addressOrigin) * 2) else {
            return
        }
        if mode == .ihex {
            let origin = cursor - 7
            guard try field(addressType(origin) == 10 ? 3 : 2, count: 2) else {
                return
            }
        }
        let dataOrigin = mode == .ihex ? cursor - 9 : try recordStart(at: cursor)
        let dataStyle = dataType(dataOrigin)
        let digits = dataSize(dataOrigin) * 2
        try setStyle(dataStyle)
        if dataStyle == 12 {
            guard try data(digits) else {
                return
            }
        }
        else if !(try advance(digits)) || cursor >= bytes.count {
            return
        }
        let checksumOrigin = try recordStart(at: cursor)
        let declared = byteCount(checksumOrigin)
        let offset = mode == .ihex ? 9 : 2
        let wanted = pair(checksumOrigin + offset + declared * 2)
        let actual = try checksum(checksumOrigin)
        _ = try field(actual >= 0 && wanted >= 0 && actual == wanted ? 16 : 17, count: 2)
    }

    /// 业务作用：Tektronix 按数字总数、记录类型、前置校验和、固定地址与交替数据区建立呈现。
    /// 参数说明: 无。
    /// 返回：当前记录的完整字段，错误的声明长度不改变原始字节或下一记录的起点。
    mutating func tektronix() throws {
        guard try field(1, count: 1) else {
            return
        }
        let lengthOrigin = cursor - 1
        let count = byteCount(lengthOrigin)
        let actualCount = try remainingDigits(from: lengthOrigin + 1)
        guard try field(count == actualCount ? 4 : 5, count: 2) else {
            return
        }
        let typeOrigin = cursor - 3
        guard try field(addressType(typeOrigin) == 10 ? 3 : 2, count: 1) else {
            return
        }
        let checksumOrigin = cursor - 4
        let actual = try checksum(checksumOrigin)
        let wanted = pair(checksumOrigin + 4)
        guard try field(actual >= 0 && wanted >= 0 && actual == wanted ? 16 : 17, count: 2) else {
            return
        }
        let addressOrigin = cursor - 6
        guard try field(addressType(addressOrigin), count: 9) else {
            return
        }
        let dataOrigin = cursor - 15
        try setStyle(12)
        _ = try data(byteCount(dataOrigin) - 14)
    }

    /// 业务作用：数据区每两个原始字符交替身份，便于定位字节且不把 Unicode 标量拆成非法端点。
    /// 参数说明:
    /// - count: 当前格式要求推进的字符数量，非正数量不消费正文。
    /// 返回：完整推进且仍有后续源字符时为真，真实行末或正文末尾时为假。
    mutating func data(_ count: Int) throws -> Bool {
        if count > 0 {
            for index in 0..<count {
                if index & 3 == 0 {
                    try setStyle(12)
                }
                else if index & 3 == 2 {
                    try setStyle(13)
                }
                guard try advance(1), cursor < bytes.count else {
                    return false
                }
            }
        }
        return cursor < bytes.count
    }

    /// 业务作用：字段切换与推进共用行边界门禁，不让缺少字段的记录消费下一行的开头。
    /// 参数说明:
    /// - style: 当前字段资源编号。
    /// - count: 当前字段要求的字符数量。
    /// 返回：字段完整且当前行仍有后续原文时为真。
    mutating func field(_ style: Int, count: Int) throws -> Bool {
        try setStyle(style)
        return try advance(count) && cursor < bytes.count
    }

    /// 业务作用：按完整 UTF-8 标量推进固定字段，真实结束符的末字节使用中性样式。
    /// 参数说明:
    /// - count: 需要推进的字符数量。
    /// 返回：未触及真实行末时为真，触及后停止当前字段并保持后续记录独立。
    mutating func advance(_ count: Int) throws -> Bool {
        guard count > 0 else {
            return true
        }
        for _ in 0..<count {
            try budget.consume()
            guard cursor < bytes.count else {
                try setStyle(0)
                return false
            }
            let byte = bytes[cursor]
            let ending = byte == 10 || byte == 13 && self.byte(cursor + 1) != 10
            if ending {
                try setStyle(0)
            }
            cursor += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
            if ending {
                return false
            }
        }
        return true
    }

    /// 业务作用：样式变化先封存此前完整字段，新身份只作用于当前位置及之后。
    /// 参数说明:
    /// - next: 新的固定样式编号。
    /// 返回：此前字段进入有界列表，原始字节顺序不改变。
    mutating func setStyle(_ next: Int) throws {
        try flush(until: min(cursor, bytes.count))
        style = next
    }

    /// 业务作用：完整字段采用原始 UTF-8 边界，连续同类片段合并且总数量保持有界。
    /// 参数说明:
    /// - end: 当前需要封存的原字节末边界。
    /// 返回：非空字段进入临时列表；容量不足时拒绝整条记录。
    mutating func flush(until end: Int) throws {
        guard end > segment else {
            return
        }
        try budget.consume()
        let start: Int
        if let previous = fields.last, previous.style == style {
            start = previous.range.lower
            fields.removeLast()
        }
        else {
            start = segment
        }
        guard fields.count < 65_536 else {
            throw NateError.message("HEX 记录超过词法片段容量。")
        }
        fields.append(
            HexField(
                range: ByteRange(start, end),
                style: style
            )
        )
        segment = end
    }
}
