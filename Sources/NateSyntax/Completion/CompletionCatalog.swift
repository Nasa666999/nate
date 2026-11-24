import Foundation
import NateCore

public struct CompletionOverload: Sendable {
    public let returnType: String
    public let description: String
    public let parameters: [String]
}

public struct CompletionEntry: Sendable {
    public let name: String
    public let isFunction: Bool
    public let overloads: [CompletionOverload]
}

public struct CompletionDefinition: Sendable {
    public let entries: [CompletionEntry]
    public let ignoresCase: Bool
    public let additionalWordCharacters: String
    public let startFunction: String
    public let stopFunction: String
    public let parameterSeparator: String

    /// 业务作用：补全 XML 与 UDL 独立校验，函数重载和参数说明完整保留。
    /// 参数说明:
    /// - data: Notepad++ 格式补全 XML。
    /// 返回：不可变补全定义；根结构、重载或容量无效时拒绝。
    public init(data: Data) throws {
        let root = try ResourceXML.parse(data)
        guard root.name == "NotepadPlus",
            let complete = root.children.first(where: {
                $0.name == "AutoComplete"
            })
        else {
            throw NateError.message("补全资源缺少 NotepadPlus / AutoComplete。")
        }
        try self.init(complete: complete, defaultsToIgnoringCase: false)
    }

    /// 业务作用：外部补全定义在进入用户语言目录前必须完整校验，含义不确定的字段不能静默成为有效配置。
    /// 参数说明:
    /// - data: 用户明确选择的 Notepad++ 格式补全 XML。
    /// 返回：原定义可以精确使用时交付不可变规则；不支持的字段、重复节点或非法分隔符会拒绝整份导入。
    public init(importing data: Data) throws {
        let root = try ResourceXML.parse(data)
        let complete = try ImportedCompletionXML.validate(root)
        try self.init(complete: complete, defaultsToIgnoringCase: true)
    }

    /// 业务作用：从已确认的资源结构生成统一的补全条目与参数规则，保持重载和参数原始顺序。
    /// 参数说明:
    /// - complete: 已确认的 AutoComplete XML 节点。
    /// - defaultsToIgnoringCase: 未声明大小写选项时采用的资源默认行为。
    /// 返回：有界的完整规则；无效名称或超过重载及参数容量时拒绝。
    private init(complete: ResourceXMLNode, defaultsToIgnoringCase: Bool) throws {
        let environment =
            complete.children.first(where: {
                $0.name == "Environment"
            })?.attributes ?? [:]
        ignoresCase = environment["ignoreCase"].map { $0 == "yes" } ?? defaultsToIgnoringCase
        additionalWordCharacters = environment["additionalWordChar"] ?? ""
        startFunction = environment["startFunc"] ?? "("
        stopFunction = environment["stopFunc"] ?? ")"
        parameterSeparator = environment["paramSeparator"] ?? ","
        entries = try complete.children.filter {
            $0.name == "KeyWord"
        }.map {
            keyword in
            guard let name = keyword.attributes["name"], !name.isEmpty, name.utf8.count <= 4096 else {
                throw NateError.message("补全条目名称为空或超过 4096 字节。")
            }
            let overloads = keyword.children.filter {
                $0.name == "Overload"
            }.map {
                overload in
                CompletionOverload(
                    returnType: overload.attributes["retVal"] ?? "",
                    description: overload.attributes["descr"] ?? "",
                    parameters: overload.children.filter {
                        $0.name == "Param"
                    }.map {
                        $0.attributes["name"] ?? ""
                    }
                )
            }
            guard overloads.count <= 256,
                overloads.allSatisfy({
                    $0.parameters.count <= 256
                })
            else {
                throw NateError.message("补全重载或参数数量超过 256 项。")
            }
            return CompletionEntry(
                name: name,
                isFunction: keyword.attributes["func"] == "yes",
                overloads: overloads
            )
        }
    }
}

public struct CompletionCatalog: Sendable {
    public let definitions: [String: CompletionDefinition]
    private let originals: [String: Data]

    /// 业务作用：从注入目录加载各语言的独立补全资源，不依赖源码目录。
    /// 参数说明:
    /// - directory: 应用包或已验证用户资源目录。
    /// 返回：完整资源代次；任一规则无效时不半发布。
    public init(directory: URL) throws {
        var loaded: [String: CompletionDefinition] = [:]
        var originals: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({
                $0.pathExtension.lowercased() == "xml"
            })
        {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            let xml = try Data(contentsOf: url)
            loaded[id] = try CompletionDefinition(data: xml)
            originals[id] = xml
        }
        definitions = loaded
        self.originals = originals
    }

    /// 业务作用：语言标识映射到独立补全表，UDL 没有补全表时不冒用其他语言。
    /// 参数说明:
    /// - language: 当前语言稳定标识。
    /// 返回：匹配资源；无规则时为空，文档单词补全仍可使用。
    public func definition(for language: String) -> CompletionDefinition? {
        definitions[Self.resourceID(language)]
    }

    /// 业务作用：编辑和导出随包补全以原始 XML 为依据，保留说明、属性和有效签名。
    /// 参数说明:
    /// - language: 当前注册表的确切语言标识。
    /// 返回：随包资源的完整原字节；无对应资源时为空。
    public func originalXML(for language: String) -> Data? {
        originals[Self.resourceID(language)]
    }

    /// 业务作用：共享的随包语言别名同时用于补全和原 XML 读取。
    /// 参数说明:
    /// - language: 当前注册表的语言标识。
    /// 返回：稳定的随包资源名称，不用于决定用户定义的语言范围。
    private static func resourceID(_ language: String) -> String {
        let aliases = ["javascript.js": "javascript", "javascript": "javascript", "baanc": "baanc"]
        return aliases[language] ?? language.lowercased()
    }
}
