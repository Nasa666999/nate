import NateCore

enum HTMLScriptAttributes {
    private static let scriptTypes: Set<String> = [
        "module", "application/ecmascript", "application/javascript", "application/x-ecmascript",
        "application/x-javascript", "text/ecmascript", "text/javascript", "text/javascript1.0",
        "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4",
        "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript",
    ]

    /// 业务作用：沿真实 HTML 开始标签确认内嵌 JavaScript，数据脚本与外部来源继续采用原始文本边界。
    /// 参数说明:
    /// - range: 已确认的 HTML script 开始标签完整原字节。
    /// - tree: 与标签同源的不可变正文。
    /// - check: 当前折叠操作的继续资格。
    /// 返回：标签具备可确认的内嵌 JavaScript 类型时成立；原属性范围过长或歧义时保留普通整段折叠。
    static func allowsInline(_ range: ByteRange, tree: PieceTree, check: () throws -> Void) throws -> Bool {
        guard range.count <= 65_536 else {
            return false
        }
        let bytes = Array(tree.bytes(in: range))
        var cursor = 7
        var type: String?
        var language: String?
        while cursor < bytes.count {
            try check()
            let byte = bytes[cursor]
            if MarkupTag.whitespace(byte) {
                cursor += 1
                continue
            }
            if byte == 47 || byte == 62 {
                break
            }
            let start = cursor
            while cursor < bytes.count,
                !MarkupTag.whitespace(bytes[cursor]), bytes[cursor] != 61, bytes[cursor] != 47,
                bytes[cursor] != 62
            {
                if cursor & 255 == 0 {
                    try check()
                }
                cursor += 1
            }
            guard start < cursor else {
                return false
            }
            let name = folded(bytes[start..<cursor])
            if name == "src" {
                // 外部资源的属性只说明实际脚本在正文之外，本次折叠不打开路径或地址。
                return false
            }
            try skipWhitespace(bytes, cursor: &cursor, check: check)
            var value = ""
            if cursor < bytes.count, bytes[cursor] == 61 {
                cursor += 1
                try skipWhitespace(bytes, cursor: &cursor, check: check)
                guard cursor < bytes.count else {
                    return false
                }
                let quote = bytes[cursor] == 34 || bytes[cursor] == 39 ? bytes[cursor] : nil
                if quote != nil {
                    cursor += 1
                }
                let start = cursor
                while cursor < bytes.count {
                    if cursor & 255 == 0 {
                        try check()
                    }
                    let byte = bytes[cursor]
                    if let quote {
                        if byte == quote {
                            break
                        }
                    }
                    else if byte == 62 || MarkupTag.whitespace(byte) {
                        break
                    }
                    cursor += 1
                }
                if name == "type" || name == "language" {
                    value = folded(bytes[start..<cursor])
                }
                if quote != nil {
                    guard cursor < bytes.count else {
                        return false
                    }
                    cursor += 1
                }
            }
            // HTML 同名属性首项有效，后继重复值不能给原数据块换成脚本身份。
            if name == "type", type == nil {
                type = value
            }
            if name == "language", language == nil {
                language = value
            }
        }
        if let type {
            return type.isEmpty || scriptTypes.contains(type)
        }
        if let language, !language.isEmpty {
            return scriptTypes.contains("text/" + language)
        }
        return true
    }

    /// 业务作用：沿原属性语法定位值或后继标点，保持本次扫描的继续资格。
    /// 参数说明:
    /// - bytes: 已确认的开始标签。
    /// - cursor: 当前属性位置，推进到首个非空白或标签末端。
    /// - check: 本次操作的继续资格。
    /// 返回：空白读取完整时推进，取消或超时时终止整个分析。
    private static func skipWhitespace(_ bytes: [UInt8], cursor: inout Int, check: () throws -> Void) throws {
        while cursor < bytes.count, MarkupTag.whitespace(bytes[cursor]) {
            if cursor & 255 == 0 {
                try check()
            }
            cursor += 1
        }
    }

    /// 业务作用：属性身份及 MIME 外观只采用 HTML 明确的 ASCII 大小写折叠。
    /// 参数说明:
    /// - bytes: 属性名称或值的完整原字节。
    /// 返回：可作稳定比较的名称；超过有效类型范围的值保持未知身份。
    private static func folded(_ bytes: ArraySlice<UInt8>) -> String {
        guard bytes.count <= 128 else {
            return " "
        }
        return String(decoding: MarkupNames.folded(Array(bytes)), as: UTF8.self)
    }
}
