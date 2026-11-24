import NateCore

struct MarkupIndentationTag {
    enum Kind {
        case open
        case close
        case empty
    }

    let kind: Kind
    let name: [UInt8]
    let range: ByteRange
    let prefix: ByteRange
}

struct MarkupIndentationLexer {
    private var scanner: MarkupLexing
    private var candidate: (offset: Int, prefix: ByteRange)?

    /// 业务作用：复用标签闭合使用的标记词法，保持注释、属性和原始文本的同一识别边界。
    /// 参数说明:
    /// - dialect: 当前明确的 HTML 或 XML 方言。
    /// 返回：等待固定正文原字节的结构观察器。
    init(dialect: MarkupDialect) {
        scanner = MarkupLexing(dialect: dialect)
    }

    /// 业务作用：记录真实标签的完整原范围及开始行前缀，不解释属性、注释或脚本的标签外观。
    /// 参数说明:
    /// - byte: 正文中的下一原始 UTF-8 字节。
    /// - offset: 当前字节在固定正文中的真实位置。
    /// - prefix: 当前物理行的全部前导空格和 Tab 范围。
    /// 返回：读完有效标签时提供结构证据，未完成内容及字面没有结构事件。
    mutating func consume(_ byte: UInt8, at offset: Int, prefix: ByteRange) -> MarkupIndentationTag? {
        let oldMode = scanner.mode
        scanner.consume(byte)
        if byte == 60,
            scanner.mode == .less || oldMode == .raw && scanner.rawProbe.count == 1 && !scanner.rawClosing
        {
            candidate = (offset, prefix)
        }
        guard let candidate else {
            return nil
        }
        if oldMode == .tag, scanner.mode != .tag {
            self.candidate = nil
            guard scanner.tag.valid, let original = scanner.tag.resolvedName else {
                return nil
            }
            let raw = Array(original.utf8)
            let name = scanner.dialect == .html ? MarkupNames.folded(raw) : raw
            if scanner.tag.closing {
                guard scanner.tag.stage != .selfClosing else {
                    return nil
                }
                return MarkupIndentationTag(
                    kind: .close,
                    name: name,
                    range: ByteRange(candidate.offset, offset + 1),
                    prefix: candidate.prefix
                )
            }
            let void =
                scanner.dialect == .html
                && MarkupLexing.voidNames.contains(String(decoding: name, as: UTF8.self))
            let empty = void || scanner.tag.stage == .selfClosing && scanner.mode != .raw
            return MarkupIndentationTag(
                kind: empty ? .empty : .open,
                name: name,
                range: ByteRange(candidate.offset, offset + 1),
                prefix: candidate.prefix
            )
        }
        if oldMode == .raw, scanner.mode == .data {
            self.candidate = nil
            return MarkupIndentationTag(
                kind: .close,
                name: scanner.rawName,
                range: ByteRange(candidate.offset, offset + 1),
                prefix: candidate.prefix
            )
        }
        return nil
    }
}
