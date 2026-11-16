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
        let environment =
            complete.children.first(where: {
                $0.name == "Environment"
            })?.attributes ?? [:]
        ignoresCase = environment["ignoreCase"] == "yes"
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

    /// 业务作用：从注入目录加载各语言的独立补全资源，不依赖源码目录。
    /// 参数说明:
    /// - directory: 应用包或已验证用户资源目录。
    /// 返回：完整资源代次；任一规则无效时不半发布。
    public init(directory: URL) throws {
        var loaded: [String: CompletionDefinition] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({
                $0.pathExtension.lowercased() == "xml"
            })
        {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            loaded[id] = try CompletionDefinition(data: Data(contentsOf: url))
        }
        definitions = loaded
    }

    /// 业务作用：语言标识映射到独立补全表，UDL 没有补全表时不冒用其他语言。
    /// 参数说明:
    /// - language: 当前语言稳定标识。
    /// 返回：匹配资源；无规则时为空，文档单词补全仍可使用。
    public func definition(for language: String) -> CompletionDefinition? {
        let aliases = ["javascript.js": "javascript", "javascript": "javascript", "baanc": "baanc"]
        return definitions[aliases[language] ?? language.lowercased()]
    }
}
