import Foundation
import NateCore

public enum SyntaxEngine {
    /// 业务作用：扫描固定行片段并传播跨行状态，不把呈现属性写回正文。
    /// 参数说明:
    /// - text: 逻辑行或连续片段。
    /// - base: 片段在快照中的 UTF-8 起点。
    /// - language: 当前语言规则。
    /// - state: 上一个安全边界的词法状态，完成后更新。
    /// 返回：用于独立绘制的语法范围。
    public static func highlight(
        _ text: String,
        base: Int,
        language: LanguageDefinition,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        SyntaxScanner(language: language).highlight(text, base: base, state: &state)
    }

    /// 业务作用：复用已确认的资源集合，维护当前片段的词法呈现并传播跨行注释状态。
    /// 参数说明:
    /// - text: 当前片段。
    /// - base: 原始正文字节起点。
    /// - language: 固定语言定义。
    /// - keywords: 与该定义一同建立的关键字集合。
    /// - state: 本流程独立词法状态。
    /// 返回：原始坐标中的样式片段，不产生编辑事务。
    static func scan(
        _ text: String,
        base: Int,
        language: LanguageDefinition,
        keywords: Set<String>,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        if ["normal", "nfo"].contains(language.id) {
            return []
        }
        let bytes = Array(text.utf8)
        var result: [SyntaxToken] = []
        var i = 0
        /// 业务作用：只在当前片段内比较词法起止标记，拒绝越界读取。
        /// 参数说明:
        /// - value: 待匹配的字面标记。
        /// - at: 当前片段字节位置。
        /// 返回：原字节完全匹配时为真。
        func matches(_ value: String, at: Int) -> Bool {
            let token = Array(value.utf8)
            return !token.isEmpty && at + token.count <= bytes.count
                && bytes[at..<(at + token.count)].elementsEqual(token)
        }
        /// 业务作用：把局部词法片段转换为所属文档的呈现范围。
        /// 参数说明:
        /// - start: 片段内起始字节。
        /// - end: 不包含的结束字节。
        /// - kind: 呈现类型。
        /// 返回：非空片段进入语法结果，不产生正文修改。
        func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if end > start {
                result.append(
                    SyntaxToken(
                        range: ByteRange(
                            base + start,
                            base + end
                        ),
                        kind: kind
                    )
                )
            }
        }
        if language.id == "markdown", bytes.first == 35 {
            emit(0, bytes.count, .heading)
            return result
        }
        while i < bytes.count {
            let start = i
            if !state.blockEnd.isEmpty {
                while i < bytes.count && !matches(state.blockEnd, at: i) {
                    i += 1
                }
                if i < bytes.count {
                    i += state.blockEnd.utf8.count
                    state.blockEnd = ""
                }
                emit(start, i, .comment)
            }
            else if matches(language.lineComment, at: i) {
                emit(i, bytes.count, .comment)
                break
            }
            else if matches(language.blockStart, at: i), !language.blockEnd.isEmpty {
                state.blockEnd = language.blockEnd
                i += language.blockStart.utf8.count
                while i < bytes.count && !matches(state.blockEnd, at: i) {
                    i += 1
                }
                if i < bytes.count {
                    i += state.blockEnd.utf8.count
                    state.blockEnd = ""
                }
                emit(start, i, .comment)
            }
            else if bytes[i] == 34 || bytes[i] == 39 || bytes[i] == 96 {
                let quote = bytes[i]
                i += 1
                while i < bytes.count {
                    if bytes[i] == 92 {
                        i = min(bytes.count, i + 2)
                    }
                    else if bytes[i] == quote {
                        i += 1
                        break
                    }
                    else {
                        i += 1
                    }
                }
                emit(start, i, .string)
            }
            else if (48...57).contains(bytes[i]) {
                i += 1
                while i < bytes.count
                    && ((48...57).contains(bytes[i]) || (65...70).contains(bytes[i])
                        || (97...102).contains(bytes[i]) || [46, 120, 88, 95].contains(bytes[i]))
                {
                    i += 1
                }
                emit(start, i, .number)
            }
            else if isWord(bytes[i]) {
                i += 1
                while i < bytes.count && (isWord(bytes[i]) || (48...57).contains(bytes[i])) {
                    i += 1
                }
                let word = String(decoding: bytes[start..<i], as: UTF8.self)
                if keywords.contains(word) || keywords.contains(word.lowercased()) {
                    emit(start, i, .keyword)
                }
            }
            else if bytes[i] == 60 && ["xml", "html", "php", "jsp", "asp"].contains(language.id),
                ["xml", "html"].contains(language.id)
                    || i + 1 < bytes.count
                        && ((65...90).contains(bytes[i + 1]) || (97...122).contains(bytes[i + 1])
                            || [33, 47, 63].contains(bytes[i + 1]))
            {
                // 嵌入脚本中的比较和移位运算不能吞掉同行字符串或注释，只有标签起始外观进入标记分支。
                i += 1
                while i < bytes.count && bytes[i] != 62 {
                    i += 1
                }
                if i < bytes.count {
                    i += 1
                }
                emit(start, i, .tag)
            }
            else {
                i += 1
            }
        }
        return result
    }

    /// 业务作用：识别词法标识符边界，UTF-8 非 ASCII 字节不被当成标点截断。
    /// 参数说明:
    /// - byte: 当前字节。
    /// 返回：可属于标识符的字节。
    static func isWord(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }
}
