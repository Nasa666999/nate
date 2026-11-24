import NateCore

struct RubyHeredoc: Equatable, Sendable {
    private let delimiter: [UInt8]
    private let allowsIndent: Bool
    let style: RubyHighlightStyle
    private var body = RubyLiteralState()

    /// 业务作用：仅从当前位置已确认的字面开端取得 heredoc 名称，普通左移运算继续按代码处理。
    /// 参数说明:
    /// - bytes: 同一实际物理行的原始内容。
    /// - start: 已知允许字面且尚未消费的字节偏移。
    /// - check: 所有光标共用的继续资格。
    /// 返回：有界的实际分隔符及声明后的字节位置，不完整或格式不符时为空。
    static func opening(in bytes: [UInt8], at start: Int, check: () throws -> Void) throws
        -> (RubyHeredoc, Int)?
    {
        guard start + 2 < bytes.count, bytes[start] == 60, bytes[start + 1] == 60 else {
            return nil
        }
        var index = start + 2
        let indented = bytes[index] == 45 || bytes[index] == 126
        if indented {
            index += 1
        }
        guard index < bytes.count else {
            return nil
        }
        let mark = bytes[index]
        let quoted = [34, 39, 96].contains(mark)
        if quoted {
            index += 1
        }
        else if !RubyIndentationLexer.nameStart(mark) {
            return nil
        }
        let name = index
        while index < bytes.count, index - name <= 256 {
            try check()
            if quoted ? bytes[index] == mark : !RubyIndentationLexer.namePart(bytes[index]) {
                break
            }
            index += 1
        }
        // 超长声明失去完整边界时不能把后续 heredoc 正文重新解释为普通 Ruby 源码。
        guard index - name <= 256 else {
            throw NateError.message("Ruby heredoc 分隔符超过 256 个原字节。")
        }
        guard index > name, !quoted || index < bytes.count && bytes[index] == mark else {
            return nil
        }
        let style: RubyHighlightStyle =
            mark == 39 ? .heredocLiteral : (mark == 96 ? .heredocCommand : .heredocString)
        let document = RubyHeredoc(
            delimiter: Array(bytes[name..<index]),
            allowsIndent: indented,
            style: style
        )
        return (document, index + (quoted ? 1 : 0))
    }

    /// 业务作用：heredoc 只在同一真实分隔符结束，缩进及代码关键词不能提前打开后续正文。
    /// 参数说明:
    /// - bytes: 当前候选物理行的原字节，排除实际结束符。
    /// 返回：真实结束标记的起点，正文内容或不匹配时为空。
    func closingOffset(in bytes: [UInt8]) -> Int? {
        // 同名文本位于跨行表达式时仍是表达式的一部分，提前结束会给后续源码错误的结构权限。
        guard body.interpolationDepth == 0 else {
            return nil
        }
        let body =
            allowsIndent
            ? bytes.drop(while: {
                $0 == 9 || $0 == 32
            }) : bytes[...]
        return body.elementsEqual(delimiter) ? body.startIndex : nil
    }

    /// 业务作用：按引用方式读取 heredoc 表达式，保留整个文档正文的结构隔离。
    /// 参数说明:
    /// - bytes: 当前 heredoc 物理行正文的完整原字节。
    /// - highlight: 调用需要记录独立原生样式时为真。
    /// - check: 本次原文读取的共同继续资格。
    /// 返回：原生调用的插值范围与当前物理换行的样式。
    mutating func scanBody(
        _ bytes: [UInt8],
        highlight: Bool,
        check: () throws -> Void
    ) throws -> (RubyInterpolationHighlights?, RubyHighlightStyle) {
        guard style != .heredocLiteral else {
            return (nil, style)
        }
        if !body.isOpen {
            body.beginHeredoc(style: style)
        }
        var events = highlight ? RubyInterpolationHighlights(initialDepth: body.interpolationDepth) : nil
        var index = 0
        try body.advance(in: bytes, from: &index, highlights: &events, check: check)
        return (events, body.liveStyle ?? style)
    }
}
