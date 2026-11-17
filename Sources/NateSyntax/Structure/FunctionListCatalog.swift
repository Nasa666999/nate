import Foundation
import NateCore

public struct FunctionListCatalog: Sendable {
    public let generation = UUID()
    public let definitions: [String: FunctionListDefinition]
    public let userAssociations: [String: String]
    public let languageAssociations: [Int: String]

    /// 业务作用：载入函数列表及独立 overrideMap，路径只能指向同一资源目录的 XML。
    /// 参数说明:
    /// - directory: 注入的随包或用户函数列表目录。
    /// 返回：完整资源代次；无效关联与规则不半发布。
    public init(directory: URL) throws {
        var definitions: [String: FunctionListDefinition] = [:]
        var users: [String: String] = [:]
        var languages: [Int: String] = [:]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter {
                $0.pathExtension.lowercased() == "xml"
            }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        for url in urls {
            let data = try Data(contentsOf: url)
            if url.lastPathComponent == "overrideMap.xml" {
                let root = try ResourceXML.parse(data)
                guard root.name == "NotepadPlus",
                    let list = root.children.first(where: {
                        $0.name == "functionList"
                    }),
                    let map = list.children.first(where: {
                        $0.name == "associationMap"
                    })
                else {
                    throw NateError.message("函数列表 overrideMap 缺少 associationMap。")
                }
                for association in map.children where association.name == "association" {
                    guard let filename = association.attributes["id"],
                        filename == URL(fileURLWithPath: filename).lastPathComponent,
                        !filename.contains(".."), filename.hasSuffix(".xml")
                    else {
                        throw NateError.message("函数列表关联必须是同一目录内的 XML 文件名。")
                    }
                    let id = String(filename.dropLast(4)).lowercased()
                    if let name = association.attributes["userDefinedLangName"], !name.isEmpty {
                        users[name] = id
                    }
                    if let value = association.attributes["langID"], let number = Int(value), number >= 0 {
                        languages[number] = id
                    }
                }
            }
            else {
                definitions[url.deletingPathExtension().lastPathComponent.lowercased()] =
                    try FunctionListDefinition(data: data)
            }
        }
        guard
            users.values.allSatisfy({
                definitions[$0] != nil
            }),
            languages.values.allSatisfy({
                definitions[$0] != nil
            })
        else {
            throw NateError.message("函数列表关联引用了缺失的规则文件。")
        }
        self.definitions = definitions
        userAssociations = users
        languageAssociations = languages
    }

    /// 业务作用：按语言身份选取结构规则，UDL 只使用显式名称关联。
    /// 参数说明:
    /// - language: 内置语言或带 udl: 前缀的稳定标识。
    /// - languageIndex: 官方内置语言枚举值；存在显式覆盖时优先。
    /// 返回：适用规则；没有规则时为空。
    public func definition(for language: String, languageIndex: Int? = nil) -> FunctionListDefinition? {
        if language.hasPrefix("udl:") {
            return userAssociations[String(language.dropFirst(4))].flatMap {
                definitions[$0]
            }
        }
        if let languageIndex, let override = languageAssociations[languageIndex] {
            return definitions[override]
        }
        return definitions[language.lowercased()]
    }
}
