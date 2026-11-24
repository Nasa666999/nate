import Foundation
import NateCore

public struct FunctionListCatalog: Sendable {
    public let generation = UUID()
    public let definitions: [String: FunctionListDefinition]
    public let associations: FunctionListAssociations?
    /// 业务作用：查看随包的 UDL 关联，与实际解析的原始映射同源。
    /// 参数说明: 无。
    /// 返回：从名称到规则键的映射，没有 overrideMap 时为空。
    public var userAssociations: [String: String] {
        associations?.userAssociations ?? [:]
    }

    /// 业务作用：查看随包的官方语言编号关联，不使用应用菜单顺序。
    /// 参数说明: 无。
    /// 返回：从固定协议编号到规则键的映射，没有 overrideMap 时为空。
    public var languageAssociations: [Int: String] {
        associations?.languageAssociations ?? [:]
    }

    /// 业务作用：载入函数列表及独立 overrideMap，关联只能指向同一随包资源目录。
    /// 参数说明:
    /// - directory: 完整的随包函数列表目录。
    /// 返回：同一资源代次的目录定义；无效关联及规则不半发布。
    public init(directory: URL) throws {
        var definitions: [String: FunctionListDefinition] = [:]
        var map: FunctionListAssociations?
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter {
                $0.pathExtension.lowercased() == "xml"
            }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        for url in urls {
            let data = try Data(contentsOf: url)
            if url.lastPathComponent == "overrideMap.xml" {
                map = try FunctionListAssociations(data: data)
            }
            else {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                guard definitions[key] == nil else {
                    throw NateError.message("函数列表规则文件名存在重复。")
                }
                definitions[key] = try FunctionListDefinition(data: data)
            }
        }
        guard map?.ruleFilenames.keys.allSatisfy({ definitions[$0] != nil }) != false else {
            throw NateError.message("函数列表关联引用了缺失的规则文件。")
        }
        self.definitions = definitions
        associations = map
    }

    /// 业务作用：按语言身份选取随包结构规则，UDL 只使用显式名称关联。
    /// 参数说明:
    /// - language: 内置语言或带 udl: 前缀的稳定标识。
    /// - languageIndex: 官方内置语言枚举值；存在显式覆盖时优先。
    /// 返回：适用规则；没有规则时为空。
    public func definition(for language: String, languageIndex: Int? = nil) -> FunctionListDefinition? {
        if let key = associations?.ruleKey(for: language, languageIndex: languageIndex) {
            return definitions[key]
        }
        return language.hasPrefix("udl:") ? nil : definitions[language.lowercased()]
    }
}
