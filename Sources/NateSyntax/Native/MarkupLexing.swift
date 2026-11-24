import Foundation

enum MarkupMode {
    case data, less, bang, tag, comment, cdata, processing, declaration, raw
}

struct MarkupLexing {
    let dialect: MarkupDialect
    var mode = MarkupMode.data
    var tag: MarkupTag
    var probe: [UInt8] = []
    var terminalCount = 0
    var declarationDepth = 0
    var declarationQuote: UInt8?
    var declarationTail: [UInt8] = []
    var returnsToDeclaration = false
    var rawName: [UInt8] = []
    var rawProbe: [UInt8] = []
    var rawClosing = false
    var rawEnd: MarkupTag?
    var rawExpected: [UInt8] = []
    var rawTail: [UInt8] = []
    var scriptEscaped = false
    var ambiguousScript = false

    static let voidNames: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track",
        "wbr", "param", "basefont", "bgsound", "frame", "keygen", "command", "isindex",
    ]
    static let rawNames: Set<String> = [
        "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "noscript",
        "plaintext",
    ]

    /// 业务作用：建立单次完整前缀分析的方言状态，字符串和声明中的外观标签不进入真实标签流程。
    /// 参数说明:
    /// - dialect: 本次固定的 HTML 或 XML 规则。
    /// 返回：尚未读取任何原文的中性状态。
    init(dialect: MarkupDialect) {
        self.dialect = dialect
        tag = MarkupTag(dialect: dialect)
    }

    /// 业务作用：按原字节推进标签、属性及不透明文本区域，不读取外部实体或执行嵌入内容。
    /// 参数说明:
    /// - byte: 当前快照中的真实 UTF-8 字节。
    /// 返回：只推进有界内部词法状态，不修改正文。
    mutating func consume(_ byte: UInt8) {
        switch mode {
        case .data:
            if byte == 60 {
                mode = .less
            }
        case .less:
            tag = MarkupTag(dialect: dialect)
            if byte == 33 {
                probe = []
                mode = .bang
            }
            else if byte == 63 {
                terminalCount = 0
                returnsToDeclaration = false
                mode = .processing
            }
            else if byte == 47 {
                tag.closing = true
                mode = .tag
            }
            else if byte == 60 {
                mode = .less
            }
            else if !MarkupTag.whitespace(byte) && byte != 62 {
                mode = .tag
                _ = tag.consume(byte)
            }
            else {
                mode = .data
            }
        case .bang:
            consumeBang(byte)
        case .tag:
            if tag.consume(byte) {
                finishTag()
            }
        case .comment:
            if byte == 62 && terminalCount >= 2 {
                mode = returnsToDeclaration ? .declaration : .data
                terminalCount = 0
                declarationTail = []
            }
            else if dialect == .html, byte == 33, terminalCount == 2 {
                // HTML 的注释错误结束符属于真实边界，XML 仍需连续的两个连字符。
                terminalCount = 3
            }
            else {
                terminalCount = byte == 45 ? (terminalCount == 3 ? 1 : min(2, terminalCount + 1)) : 0
            }
        case .cdata:
            if byte == 62 && terminalCount >= 2 {
                mode = .data
                terminalCount = 0
            }
            else {
                terminalCount = byte == 93 ? min(2, terminalCount + 1) : 0
            }
        case .processing:
            if byte == 62 && terminalCount == 1 {
                mode = returnsToDeclaration ? .declaration : .data
                terminalCount = 0
                declarationTail = []
            }
            else {
                terminalCount = byte == 63 ? 1 : 0
            }
        case .declaration:
            consumeDeclaration(byte)
        case .raw:
            consumeRaw(byte)
        }
    }

    /// 业务作用：仅在实际开始标签已完整结束时生成闭合建议，虚拟空白按真实输入前缀参与判定。
    /// 参数说明:
    /// - leadingSpaces: 原完整选择明确拥有的虚拟定位空格数。
    /// 返回：保留原名称大小写及字节的闭合标签；非标签、未闭合属性、声明或空元素时为空。
    func proposedClosure(leadingSpaces: Int) -> String? {
        guard mode == .tag else {
            return nil
        }
        var candidate = tag
        if leadingSpaces > 0 {
            _ = candidate.consume(32)
        }
        guard candidate.consume(62), candidate.valid, !candidate.closing,
            candidate.stage != .selfClosing, let name = candidate.resolvedName
        else {
            return nil
        }
        let folded = String(decoding: MarkupNames.folded(Array(name.utf8)), as: UTF8.self)
        guard dialect != .html || !Self.voidNames.contains(folded) else {
            return nil
        }
        return "</" + name + ">"
    }

    /// 业务作用：完成标签后进入 HTML 原始文本区域，script/style 等正文中的尖括号不触发普通标签补全。
    /// 参数说明: 无。
    /// 返回：有效 HTML 原始文本开始标签切换状态，其它完整标签回到普通正文。
    private mutating func finishTag() {
        mode = .data
        guard dialect == .html, !tag.closing, let name = tag.resolvedName else {
            return
        }
        let folded = MarkupNames.folded(Array(name.utf8))
        guard Self.rawNames.contains(String(decoding: folded, as: UTF8.self)) else {
            return
        }
        // HTML 原始文本元素上的尾随斜杠不赋予 XML 自闭合语义，后续内容仍须保持不透明。
        rawName = folded
        rawExpected = [60, 47] + folded
        rawProbe = []
        rawClosing = false
        rawEnd = nil
        rawTail = []
        scriptEscaped = false
        ambiguousScript = false
        mode = .raw
    }

    /// 业务作用：声明起点先确认注释和 CDATA，未匹配的声明保持不透明而不猜测内部标签。
    /// 参数说明:
    /// - byte: 当前声明起点的下一字节。
    /// 返回：匹配后切换明确状态，短前缀缓冲不超过七字节。
    private mutating func consumeBang(_ byte: UInt8) {
        probe.append(byte)
        if probe.elementsEqual("--".utf8) {
            mode = .comment
            terminalCount = 0
            returnsToDeclaration = false
        }
        else if probe.elementsEqual("[CDATA[".utf8) {
            mode = .cdata
            terminalCount = 0
        }
        else if "--".utf8.starts(with: probe) || "[CDATA[".utf8.starts(with: probe) {
            return
        }
        else {
            let pending = probe
            probe = []
            declarationDepth = 0
            declarationQuote = nil
            declarationTail = []
            mode = .declaration
            for value in pending {
                consumeDeclaration(value)
            }
        }
    }

    /// 业务作用：DOCTYPE 内部子集、引号、注释与处理指令不提前开放普通标签识别。
    /// 参数说明:
    /// - byte: 当前声明原字节。
    /// 返回：只在引号外且内部子集已结束的真正结束符处回到正文。
    private mutating func consumeDeclaration(_ byte: UInt8) {
        if let quote = declarationQuote {
            if byte == quote {
                declarationQuote = nil
            }
            return
        }
        if byte == 34 || byte == 39 {
            declarationQuote = byte
            declarationTail = []
            return
        }
        declarationTail.append(byte)
        if declarationTail.count > 4 {
            declarationTail.removeFirst()
        }
        if declarationTail.suffix(4).elementsEqual("<!--".utf8) {
            returnsToDeclaration = true
            terminalCount = 0
            mode = .comment
        }
        else if declarationTail.suffix(2).elementsEqual("<?".utf8) {
            returnsToDeclaration = true
            terminalCount = 0
            mode = .processing
        }
        else if byte == 91 {
            declarationDepth += 1
        }
        else if byte == 93 {
            declarationDepth = max(0, declarationDepth - 1)
        }
        else if byte == 62 && declarationDepth == 0 {
            mode = .data
            declarationTail = []
        }
    }

    /// 业务作用：HTML 原始文本只识别自身结束标签，嵌入语言中的普通标签外观始终保持字面。
    /// 参数说明:
    /// - byte: 当前原始文本字节。
    /// 返回：确认真实结束标签后恢复正文；复杂 script 双重转义保持不透明直到当前分析结束。
    private mutating func consumeRaw(_ byte: UInt8) {
        guard !rawName.elementsEqual("plaintext".utf8) else {
            return
        }
        let folded = (65...90).contains(byte) ? byte + 32 : byte
        rawTail.append(folded)
        if rawTail.count > 16 {
            rawTail.removeFirst()
        }
        if rawName.elementsEqual("script".utf8) {
            if rawTail.suffix(4).elementsEqual("<!--".utf8) {
                scriptEscaped = true
            }
            if scriptEscaped, MarkupTag.whitespace(folded) || folded == 47 || folded == 62,
                rawTail.dropLast().suffix(7).elementsEqual("<script".utf8)
            {
                // 双重转义缺少完整 HTML 脚本状态证据时，只保留直接输入，不把后续片段猜测成标签。
                ambiguousScript = true
            }
            if !ambiguousScript, rawTail.suffix(3).elementsEqual("-->".utf8) {
                scriptEscaped = false
            }
        }
        guard !ambiguousScript else {
            return
        }
        if rawClosing {
            if rawEnd?.consume(byte) == true {
                mode = .data
                rawClosing = false
                rawEnd = nil
                rawProbe = []
            }
            return
        }
        let expected = rawExpected
        if rawProbe.count == expected.count {
            if byte == 62 {
                mode = .data
                rawProbe = []
                return
            }
            if MarkupTag.whitespace(byte) || byte == 47 {
                rawClosing = true
                var end = MarkupTag(dialect: .html)
                end.name = rawName
                end.resolvedName = String(decoding: rawName, as: UTF8.self)
                end.closing = true
                end.stage = .beforeAttribute
                _ = end.consume(byte)
                rawEnd = end
                return
            }
            rawProbe = []
        }
        if rawProbe.isEmpty {
            if byte == 60 {
                rawProbe = [60]
            }
        }
        else if expected[rawProbe.count] == folded {
            rawProbe.append(folded)
        }
        else {
            rawProbe = byte == 60 ? [60] : []
        }
    }
}
