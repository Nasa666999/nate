import Foundation
import NateCore

public enum SyntaxKind: String, Sendable {
    case keyword, string, comment, number, punctuation, heading, tag, text
}

public struct SyntaxToken: Sendable {
    public let range: ByteRange
    public let kind: SyntaxKind
    public let foreground: String?
    public let fontStyle: Int

    /// 业务作用：携带可配置语法呈现，样式不进入正文历史。
    /// 参数说明:
    /// - range: 所属快照字节范围。
    /// - kind: 默认主题分类。
    /// - foreground: 资源显式指定的前景色，为空时继承主题。
    /// - fontStyle: UDL 粗体、斜体和下划线位集合。
    /// 返回：独立呈现属性。
    public init(range: ByteRange, kind: SyntaxKind, foreground: String? = nil, fontStyle: Int = 0) {
        self.range = range
        self.kind = kind
        self.foreground = foreground
        self.fontStyle = fontStyle
    }
}

public struct SyntaxState: Sendable, Equatable {
    public var blockEnd = ""
    public var quote: UInt8?

    /// 业务作用：为行间词法传播建立中性状态。
    /// 参数说明: 无。
    /// 返回：未处于跨行注释或字符串的状态。
    public init() {}
}

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
        if ["normal", "nfo"].contains(language.id) {
            return []
        }
        let bytes = Array(text.utf8)
        let keywords = Set(language.keywords)
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
                result.append(SyntaxToken(range: ByteRange(base + start, base + end), kind: kind))
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
            else if bytes[i] == 60 && ["xml", "html", "php", "jsp", "asp"].contains(language.id) {
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
