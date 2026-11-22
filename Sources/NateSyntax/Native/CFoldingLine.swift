import Foundation
import NateCore

struct CFoldingLine {
    let bytes: [UInt8]
    let base: Int
    let tokens: [SyntaxToken]
    var blockComment: Bool
    var lineComment: Bool
    var preprocessor: Bool
    var streamComment: Bool
    var blockStar: Bool
    var budget: ANSILexingBudget

    /// 业务作用：只从 C 词法已确认的代码、注释及预处理身份累计层级，字面内容不能创造折叠。
    /// 参数说明: 无。
    /// 返回：当前物理行的层级变化；跨行注释身份与共同预算一并保留。
    mutating func delta() throws -> Int {
        var change = 0
        var cursor = 0
        var tokenIndex = 0
        while cursor < bytes.count {
            try budget.consume()
            while tokenIndex < tokens.count, tokens[tokenIndex].range.upper <= base + cursor {
                tokenIndex += 1
            }
            let token =
                tokenIndex < tokens.count && tokens[tokenIndex].range.lower <= base + cursor
                ? tokens[tokenIndex] : nil
            let byte = bytes[cursor]
            if token?.lexicalStyle == "c:preprocessor"
                || ["script:9", "script:23", "script:24"].contains(token?.lexicalStyle ?? "")
            {
                preprocessor = true
            }
            if preprocessor && !blockComment && !lineComment, byte == 35 {
                change += try directive(at: cursor + 1)
            }
            if token?.kind == .comment {
                if !blockComment && !lineComment, byte == 47, cursor + 1 < bytes.count {
                    if bytes[cursor + 1] == 47 {
                        lineComment = true
                    }
                    else if bytes[cursor + 1] == 42 {
                        blockComment = true
                        blockStar = false
                        // 宏体中的块注释属于预处理样式，不额外改变主代码折叠层级。
                        streamComment = !preprocessor
                        if streamComment {
                            change += 1
                        }
                        cursor += 2
                        continue
                    }
                }
                if blockComment {
                    if byte == 92, cursor + 1 < bytes.count, [10, 13].contains(bytes[cursor + 1]) {
                        // 块注释结束符必须在原文相邻，物理续行会解除前一个星号的结束候选。
                        blockStar = false
                        cursor +=
                            bytes[cursor + 1] == 13 && cursor + 2 < bytes.count
                                && bytes[cursor + 2] == 10 ? 3 : 2
                        continue
                    }
                    if blockStar && byte == 47 {
                        if streamComment {
                            change -= 1
                        }
                        blockComment = false
                        blockStar = false
                        streamComment = false
                    }
                    else {
                        blockStar = byte == 42
                    }
                }
            }
            else if token?.lexicalStyle == "c:punctuation" || token?.lexicalStyle == "script:10" {
                if [40, 91, 123].contains(byte) {
                    change += 1
                }
                else if [41, 93, 125].contains(byte) {
                    change -= 1
                }
            }
            cursor += 1
        }
        return change
    }

    /// 业务作用：按原始预处理样式识别条件与区域层级，不展开宏或推测条件真假。
    /// 参数说明:
    /// - offset: 已确认预处理井号后的原字节位置。
    /// 返回：起始指令增加一层，结束指令减少一层，其它指令保持当前层级。
    mutating func directive(at offset: Int) throws -> Int {
        var cursor = offset
        while cursor < bytes.count, bytes[cursor] == 9 || bytes[cursor] == 32 {
            try budget.consume()
            cursor += 1
        }
        if try matches("region", at: cursor) || matches("if", at: cursor) {
            return 1
        }
        if try matches("end", at: cursor) {
            return -1
        }
        if try matches("pragma", at: cursor) {
            cursor += 6
            guard cursor < bytes.count, bytes[cursor] == 9 || bytes[cursor] == 32 else {
                return 0
            }
            while cursor < bytes.count, bytes[cursor] == 9 || bytes[cursor] == 32 {
                try budget.consume()
                cursor += 1
            }
            if try matches("region", at: cursor) {
                return 1
            }
            if try matches("endregion", at: cursor) {
                return -1
            }
        }
        return 0
    }

    /// 业务作用：预处理前缀采用有限 ASCII 字节比较，名称不经过 Unicode 合并或无界字符串切分。
    /// 参数说明:
    /// - name: 固定的指令前缀。
    /// - offset: 当前行内候选起点。
    /// 返回：完整前缀相等时为真，所有比较均计入本轮预算。
    mutating func matches(_ name: String, at offset: Int) throws -> Bool {
        for (index, byte) in name.utf8.enumerated() {
            try budget.consume()
            guard offset + index < bytes.count, bytes[offset + index] == byte else {
                return false
            }
        }
        return true
    }
}
