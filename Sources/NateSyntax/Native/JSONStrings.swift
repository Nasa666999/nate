import Foundation

extension JSONLexing {
    var stringStyle: String {
        if state.quote == 39 && !extended {
            return "invalid"
        }
        return state.propertyString ? "property" : "string"
    }

    /// 业务作用：传播原始引号与转义状态，转义和非法内容仍属于字符串，不能生成结构括号。
    /// 参数说明: 无。
    /// 返回：消费一个完整标量或转义步骤，实际行结束只允许 JSON5 反斜杠续行。
    mutating func stringByte() throws {
        let start = cursor
        let byte = bytes[cursor]
        if state.skipLineFeed {
            state.skipLineFeed = false
            if byte == 10 {
                cursor += 1
                try emit(start, cursor, kind: .string, style: state.invalidEscape ? "invalid" : "escape")
                return
            }
        }
        if state.hexadecimalDigits > 0 {
            if JSONNumbers.hexadecimal(byte) {
                state.hexadecimalDigits -= 1
                cursor += 1
                try emit(start, cursor, kind: .string, style: state.invalidEscape ? "invalid" : "escape")
                return
            }
            // 残缺转义不能吞掉真实结束引号或换行；当前标量重新按字符串边界解释。
            state.hexadecimalDigits = 0
        }
        if state.escape {
            state.escape = false
            let width = scalarWidth(at: cursor)
            var valid = false
            if byte == 117 {
                state.hexadecimalDigits = 4
                valid = true
            }
            else if extended && byte == 120 {
                state.hexadecimalDigits = 2
                valid = true
            }
            else if byte == 10 || byte == 13 || lineSeparatorWidth(at: cursor) > 0 {
                valid = extended
                state.skipLineFeed = extended && byte == 13
                if !extended {
                    state.quote = nil
                }
            }
            else if extended {
                valid = !JSONNumbers.decimal(byte)
                if byte == 48 {
                    valid = cursor + 1 == bytes.count || !JSONNumbers.decimal(bytes[cursor + 1])
                }
            }
            else {
                valid = "\"\\/bfnrt".utf8.contains(byte)
            }
            cursor += width
            try emit(
                start,
                cursor,
                kind: .string,
                style: valid && !state.invalidEscape ? "escape" : "invalid"
            )
            return
        }
        if byte == state.quote {
            cursor += 1
            try emit(start, cursor, kind: .string, style: stringStyle)
            state.quote = nil
            state.propertyString = false
        }
        else if byte == 92 {
            state.escape = true
            state.invalidEscape = false
            if cursor + 1 < bytes.count {
                let next = bytes[cursor + 1]
                let count = next == 117 ? 4 : (extended && next == 120 ? 2 : 0)
                if count > 0 {
                    state.invalidEscape =
                        cursor + 2 + count > bytes.count
                        || !bytes[(cursor + 2)..<min(bytes.count, cursor + 2 + count)].allSatisfy(
                            JSONNumbers.hexadecimal
                        )
                }
            }
            cursor += 1
            try emit(start, cursor, kind: .string, style: state.invalidEscape ? "invalid" : "escape")
        }
        else if byte == 10 || byte == 13 {
            cursor += 1
            if byte == 13, cursor < bytes.count, bytes[cursor] == 10 {
                cursor += 1
            }
            try emit(start, cursor, kind: .string, style: "invalid")
            state.quote = nil
            state.propertyString = false
        }
        else {
            cursor += scalarWidth(at: cursor)
            try emit(start, cursor, kind: .string, style: byte < 32 && !extended ? "invalid" : stringStyle)
        }
    }

    /// 业务作用：跨行块注释保留终止证据，行注释在所有 JSON5 行终止符处结束。
    /// 参数说明: 无。
    /// 返回：消费当前注释标量；注释中的字符串和括号始终不进入容器状态。
    mutating func commentByte() throws {
        let start = cursor
        let byte = bytes[cursor]
        if state.lineComment, byte == 10 || byte == 13 || lineSeparatorWidth(at: cursor) > 0 {
            state.lineComment = false
            cursor += scalarWidth(at: cursor)
            return
        }
        if state.blockComment {
            if state.blockStar && byte == 47 {
                state.blockComment = false
                state.blockStar = false
            }
            else {
                state.blockStar = byte == 42
            }
        }
        cursor += scalarWidth(at: cursor)
        try emit(start, cursor, kind: .comment, style: "comment")
    }

    /// 业务作用：完整有效 UTF-8 输入按标量推进，呈现范围不切断多字节字符。
    /// 参数说明:
    /// - offset: 当前行的有效标量起点。
    /// 返回：该标量的 UTF-8 字节数。
    func scalarWidth(at offset: Int) -> Int {
        let byte = bytes[offset]
        if byte < 128 {
            return 1
        }
        if byte < 224 {
            return 2
        }
        return byte < 240 ? 3 : 4
    }

    /// 业务作用：从 Swift 已确认有效的 UTF-8 原文读取码点，名称和空白判定不创建临时字符串。
    /// 参数说明:
    /// - offset: 当前完整标量的首字节。
    /// 返回：原始 Unicode 码点，不归一化或替换正文。
    func scalarValue(at offset: Int) -> UInt32 {
        let width = scalarWidth(at: offset)
        if width == 1 {
            return UInt32(bytes[offset])
        }
        let mask: UInt8 = width == 2 ? 31 : (width == 3 ? 15 : 7)
        var value = UInt32(bytes[offset] & mask)
        for index in (offset + 1)..<(offset + width) {
            value = (value << 6) | UInt32(bytes[index] & 63)
        }
        return value
    }

    /// 业务作用：识别 JSON5 的 Unicode 行分隔符，原始字符串中的这些码点仍允许保留。
    /// 参数说明:
    /// - offset: 当前标量起点。
    /// 返回：U+2028 或 U+2029 返回三字节，其它码点为零。
    func lineSeparatorWidth(at offset: Int) -> Int {
        guard offset + 2 < bytes.count, bytes[offset] == 226, bytes[offset + 1] == 128,
            bytes[offset + 2] == 168 || bytes[offset + 2] == 169
        else {
            return 0
        }
        return 3
    }

    /// 业务作用：按方言识别空白，JSON 严格模式不接受 JSON5 额外空白。
    /// 参数说明:
    /// - offset: 当前有效标量起点。
    /// 返回：合法空白的完整字节宽度，其它为零。
    func whitespaceWidth(at offset: Int) -> Int {
        let byte = bytes[offset]
        if [9, 10, 13, 32].contains(byte) {
            return 1
        }
        guard extended else {
            return 0
        }
        if byte == 11 || byte == 12 {
            return 1
        }
        if byte < 128 {
            return 0
        }
        let width = scalarWidth(at: offset)
        let scalar = scalarValue(at: offset)
        return [0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff].contains(scalar)
            || (0x2000...0x200a).contains(scalar) ? width : 0
    }
}
