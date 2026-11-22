import Foundation
import NateCore

public enum UDLDecimalSeparator: Int, Sendable {
    case dot = 0
    case comma = 1
    case both = 2
}

public enum UDLLineCommentPosition: Int, Sendable {
    case anywhere = 0
    case lineStart = 1
    case leadingWhitespace = 2
}

public struct UDLStyle: Sendable {
    public var name: String
    public var foreground: String?
    public var background: String?
    public var nesting: UInt32
    public var fontStyle: Int
}

public struct UDLDefinition: Sendable {
    public private(set) var generation = UUID()
    public var name: String {
        didSet {
            generation = UUID()
        }
    }
    public var extensions: [String] {
        didSet {
            generation = UUID()
        }
    }
    public var caseIgnored: Bool {
        didSet {
            generation = UUID()
        }
    }
    public var decimalSeparator: UDLDecimalSeparator = .dot {
        didSet {
            generation = UUID()
        }
    }
    public var lineCommentPosition: UDLLineCommentPosition = .anywhere {
        didSet {
            generation = UUID()
        }
    }
    public var allowFoldOfComments = false {
        didSet {
            generation = UUID()
        }
    }
    public var foldCompact = false {
        didSet {
            generation = UUID()
        }
    }
    public var prefix: Set<Int> {
        didSet {
            generation = UUID()
        }
    }
    public var lists: [String: [String]] {
        didSet {
            generation = UUID()
        }
    }
    public var styles: [String: UDLStyle] {
        didSet {
            generation = UUID()
        }
    }
    public var originalXML: Data {
        didSet {
            generation = UUID()
        }
    }
    public var diagnostics: [String] {
        didSet {
            generation = UUID()
        }
    }
    public var id: String {
        "udl:" + name
    }

    /// 业务作用：UDL 作为独立语言进入同一识别与选择入口。
    /// 参数说明: 无。
    /// 返回：保留 UDL 关联的语言定义，高亮仍由独立 UDL 规则执行。
    public func languageDefinition() -> LanguageDefinition {
        LanguageDefinition(
            id: id,
            name: name,
            extensions: extensions,
            lineComment: "",
            blockStart: "",
            blockEnd: "",
            keywords: (1...8).flatMap {
                lists["Keywords\($0)"] ?? []
            }
        )
    }
}

public enum UDLImporter {
    /// 业务作用：完整验证 XML 后发布 UDL，禁止实体、DTD 和隐式联网。
    /// 参数说明:
    /// - data: 用户或随包的原始 XML。
    /// 返回：完整定义集合；规模、类型或格式错误保留旧有效配置。
    public static func parse(_ data: Data) throws -> [UDLDefinition] {
        guard data.count <= 4_194_304, let source = String(data: data, encoding: .utf8),
            !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
            !source.localizedCaseInsensitiveContains("<!ENTITY")
        else {
            throw NateError.message("UDL 必须为不含 DTD 与实体声明、大小不超过 4 MB 的 UTF-8 XML。")
        }
        let delegate = UDLXMLReader(original: data)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure
                ?? NateError.message(parser.parserError?.localizedDescription ?? "UDL XML 无效。")
        }
        guard !delegate.definitions.isEmpty,
            Set(delegate.definitions.map(\.name)).count == delegate.definitions.count
        else {
            throw NateError.message("UDL 没有有效语言定义，或同一文件出现重复名称。")
        }
        let copies = delegate.definitions.count - 1
        // 共享根说明会进入每个语言的实际结果，展开后的清单同样必须满足完整资源容量。
        guard delegate.diagnosticCount + copies * delegate.rootDiagnostics.count <= 4096,
            delegate.diagnosticBytes + copies
                * delegate.rootDiagnostics.reduce(
                    0,
                    {
                        $0 + $1.utf8.count
                    }
                )
                <= 524_288
        else {
            throw NateError.message("UDL 共享兼容说明展开超过完整资源容量，定义未发布。")
        }
        return delegate.definitions.map {
            var definition = $0
            definition.diagnostics += delegate.rootDiagnostics
            return definition
        }
    }

    /// 业务作用：UDL 的双括号短语是字面规则，不解释为通用正则。
    /// 参数说明:
    /// - text: 关键字或分隔符列表。
    /// - preserveIndexedGroups: 注释与分隔符保留编号后双括号语法，替代项不能提前变成普通短语。
    /// 返回：保留短语内部空格的有序标记。
    static func words(_ text: String, preserveIndexedGroups: Bool = false) -> [String] {
        var result: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace {
                i += 1
            }
            guard i < chars.count else {
                break
            }
            let start = i
            let numbered =
                i + 3 < chars.count && chars[i].isNumber && chars[i + 1].isNumber && chars[i + 2] == "("
                && chars[i + 3] == "("
            if numbered {
                i += 2
            }
            if i + 1 < chars.count && chars[i] == "(" && chars[i + 1] == "(" {
                i += 2
                let inside = i
                while i + 1 < chars.count && !(chars[i] == ")" && chars[i + 1] == ")") {
                    i += 1
                }
                if numbered, preserveIndexedGroups {
                    result.append(String(chars[start..<min(chars.count, i + 2)]))
                }
                else {
                    result.append(
                        (numbered ? String(chars[start..<(start + 2)]) : "") + String(chars[inside..<i])
                    )
                }
                i = min(chars.count, i + 2)
            }
            else {
                while i < chars.count && !chars[i].isWhitespace {
                    i += 1
                }
                result.append(String(chars[start..<i]))
            }
        }
        return result
    }
}

private final class UDLXMLReader: NSObject, XMLParserDelegate {
    let original: Data
    var definitions: [UDLDefinition] = []
    var current: UDLDefinition?
    var depth = 0
    var nodes = 0
    var keywordName: String?
    var keywordText = ""
    var failure: NateError?
    var elements: [String] = []
    var ignoredDepth: Int?
    var rootDiagnostics: [String] = []
    var diagnosticCount = 0
    var diagnosticBytes = 0

    /// 业务作用：为一次受限导入保留完整原定义，未知字段不会在导出时丢失。
    /// 参数说明:
    /// - original: 已经过安全预检的 XML。
    /// 返回：只在本次解析中使用的读取器。
    init(original: Data) {
        self.original = original
    }

    /// 业务作用：逐节点校验深度、数量、命名和字段类型。
    /// 参数说明:
    /// - parser: 当前 XML 读取器。
    /// - elementName: 元素名称。
    /// - namespaceURI: XML 命名空间。
    /// - qName: 完整名称。
    /// - attributeDict: 原始属性。
    /// 返回：合法字段进入临时定义，失败终止而不半发布。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        depth += 1
        nodes += 1
        let parent = elements.last
        elements.append(elementName)
        guard depth <= 64, nodes <= 20_000,
            elementName.utf8.count <= 256, attributeDict.count <= 128,
            attributeDict.keys.allSatisfy({
                $0.utf8.count <= 256
            }),
            attributeDict.values.allSatisfy({
                $0.utf8.count <= 100_000
            })
        else {
            failure = .message("UDL 超出节点、深度或字段长度预算。")
            parser.abortParsing()
            return
        }
        let path = elements.joined(separator: "/")
        // 扩展子树只保留原文与说明，其中的同名字段不能取得有效规则的配置权限。
        if ignoredDepth != nil || UDLCompatibility.attributes[elementName] == nil {
            ignoredDepth = ignoredDepth ?? depth
            appendDiagnostics(["未应用元素 \(path)；原 XML 已保留。"], parser: parser)
            appendDiagnostics(
                attributeDict.keys.sorted().map {
                    "未应用字段 \(path)/@\($0)；原 XML 已保留。"
                },
                parser: parser
            )
            return
        }
        // 已知字段只有在自己的容器内才能取得配置权限，错误位置不能成为第二条隐式发布通道。
        guard UDLCompatibility.permits(elementName, parent: parent) else {
            failure = .message("UDL 元素 \(path) 不在允许的容器内。")
            parser.abortParsing()
            return
        }
        switch elementName {
        case "UserLang":
            guard current == nil, let name = attributeDict["name"], !name.isEmpty, name.count <= 200 else {
                failure = .message("UDL 语言名称为空、过长或非法嵌套。")
                parser.abortParsing()
                return
            }
            current = UDLDefinition(
                name: name,
                extensions: (attributeDict["ext"] ?? "").split(whereSeparator: \.isWhitespace).map(
                    String.init
                ),
                caseIgnored: false,
                prefix: [],
                lists: [:],
                styles: [:],
                originalXML: original,
                diagnostics: []
            )
            if let version = attributeDict["udlVersion"], version != "2.1" && version != "2.0" {
                appendDiagnostics(["UDL 格式 \(version) 可能包含尚未识别的规则；原定义完整保留。"], parser: parser)
            }
        case "Global":
            current?.caseIgnored = attributeDict["caseIgnored"] == "yes"
            if let value = attributeDict["decimalSeparator"] {
                guard let raw = Int(value), let separator = UDLDecimalSeparator(rawValue: raw) else {
                    failure = .message("UDL 小数分隔符必须为点号、逗号或同时允许两者。")
                    parser.abortParsing()
                    return
                }
                current?.decimalSeparator = separator
            }
            if let value = attributeDict["forcePureLC"] {
                guard let raw = Int(value), let position = UDLLineCommentPosition(rawValue: raw) else {
                    failure = .message("UDL 行注释位置必须为任意位置、严格行首或仅前导空白。")
                    parser.abortParsing()
                    return
                }
                current?.lineCommentPosition = position
            }
            for key in ["allowFoldOfComments", "foldCompact"] {
                if let value = attributeDict[key], value != "yes" && value != "no" {
                    failure = .message("UDL 的 \(key) 必须为 yes 或 no。")
                    parser.abortParsing()
                    return
                }
            }
            current?.allowFoldOfComments = attributeDict["allowFoldOfComments"] == "yes"
            current?.foldCompact = attributeDict["foldCompact"] == "yes"
        case "Prefix":
            for group in 1...8 where attributeDict["Keywords\(group)"] == "yes" {
                current?.prefix.insert(group)
            }
        case "Keywords":
            keywordName = attributeDict["name"]
            keywordText = ""
        case "WordsStyle":
            guard let name = attributeDict["name"] else {
                failure = .message("UDL WordsStyle 缺少 name。")
                parser.abortParsing()
                return
            }
            let nesting = UInt32(attributeDict["nesting"] ?? "0")
            let style = Int(attributeDict["fontStyle"] ?? "0")
            guard let nesting, let style, (0...7).contains(style) else {
                failure = .message("UDL 样式或 nesting 数值无效。")
                parser.abortParsing()
                return
            }
            let colorStyle = Int(attributeDict["colorStyle"] ?? "3") ?? 3
            current?.styles[name] = UDLStyle(
                name: name,
                foreground: colorStyle & 1 != 0 ? attributeDict["fgColor"] : nil,
                background: colorStyle & 2 != 0 ? attributeDict["bgColor"] : nil,
                nesting: nesting,
                fontStyle: style
            )
        case "NotepadPlus", "Settings", "KeywordLists", "Styles": break
        default: break
        }
        do {
            appendDiagnostics(
                try UDLCompatibility.messages(element: elementName, values: attributeDict, path: path),
                parser: parser
            )
        }
        catch {
            failure = .message(error.localizedDescription)
            parser.abortParsing()
        }
    }

    /// 业务作用：按 XML 解码后的字面内容收集规则，同时限制展开规模。
    /// 参数说明:
    /// - parser: 当前解析器。
    /// - string: 当前文字片段。
    /// 返回：只追加到当前关键字列表，不解释为代码。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard keywordName != nil, ignoredDepth == nil else {
            return
        }
        keywordText += string
        if keywordText.utf8.count > 1_048_576 {
            failure = .message("UDL 单项规则超过 1 MB。")
            parser.abortParsing()
        }
    }

    /// 业务作用：元素完整结束后才固化规则和语言定义。
    /// 参数说明:
    /// - parser: 当前解析器。
    /// - elementName: 结束元素。
    /// - namespaceURI: 命名空间。
    /// - qName: 完整元素名。
    /// 返回：完整语言进入临时结果，调用方统一发布。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            depth -= 1
            elements.removeLast()
        }
        if let ignoredDepth {
            if depth == ignoredDepth {
                self.ignoredDepth = nil
            }
            return
        }
        if elementName == "Keywords", let name = keywordName {
            current?.lists[name] = UDLImporter.words(
                keywordText,
                preserveIndexedGroups: name == "Comments" || name == "Delimiters"
            )
            keywordName = nil
        }
        if elementName == "UserLang", let definition = current {
            guard definitions.count < 256 else {
                failure = .message("UDL 单份资源超过 256 个语言定义。")
                parser.abortParsing()
                return
            }
            definitions.append(definition)
            current = nil
        }
    }

    /// 业务作用：兼容说明逐项保留来源路径，同时限定累计数量与内存，超量时不发布缺少完整说明的定义。
    /// 参数说明:
    /// - messages: 当前节点尚未应用的具体字段或规则。
    /// - parser: 本次 XML 解析器。
    /// 返回：说明进入所属语言或整份资源；超过 4096 项或 512 KiB 时整体拒绝导入。
    private func appendDiagnostics(_ messages: [String], parser: XMLParser) {
        for message in messages {
            diagnosticCount += 1
            diagnosticBytes += message.utf8.count
            // 说明不完整会掩盖未应用字段，超量时拒绝整份定义而不是发布截短的报告。
            guard diagnosticCount <= 4096, diagnosticBytes <= 524_288 else {
                failure = .message("UDL 兼容说明超过 4096 项或 512 KiB，完整定义未发布。")
                parser.abortParsing()
                return
            }
            if current != nil {
                current?.diagnostics.append(message)
            }
            else {
                rootDiagnostics.append(message)
            }
        }
    }

    /// 业务作用：外部实体没有读取权限，导入不能触发网络或本机文件访问。
    /// 参数说明:
    /// - parser: 当前解析器。
    /// - name: 实体名称。
    /// - systemID: 请求的外部位置。
    /// 返回：拒绝提供外部内容并终止解析。
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = .message("UDL 禁止外部实体。")
        parser.abortParsing()
        return nil
    }
}
