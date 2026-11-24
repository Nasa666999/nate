import Foundation
import NateCore

public struct LanguageDefinition: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var extensions: [String]
    public var lineComment: String
    public var blockStart: String
    public var blockEnd: String
    public var keywords: [String]
    public var keywordGroups: [String: [String]]?
    var identifierRules: UnicodeIdentifierRules?
    var terminalStyles: [String: LanguageTokenStyle]?
    var lexicalStyles: [String: LanguageTokenStyle]?
    var embeddedScriptRules: ScriptRules? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, extensions, lineComment, blockStart, blockEnd, keywords, keywordGroups
        case identifierRules, terminalStyles, lexicalStyles
    }

    /// 业务作用：按内置语言身份选择共享 C 词法与折叠规则，避免把仅有相似括号的语言误归入同一语法。
    /// 参数说明: 无。
    /// 返回：C、C++、Java、C#、Go、Swift、ActionScript、独立 JavaScript、TypeScript 与资源文件为真。
    public var usesSharedCLexer: Bool {
        ["c", "cpp", "java", "cs", "go", "swift", "actionscript", "rc", "javascript.js", "typescript"]
            .contains(id)
    }

    /// 业务作用：几何只等待可能改变字体或隐藏字符的内置样式，纯颜色资源不阻断原生列定位。
    /// 参数说明: 无。
    /// 返回：ANSI 控制序列或实际字体装饰可能改变字形时为真，其它内置资源的基础字体已具备完整证据。
    public var requiresLexicalGeometry: Bool {
        if ["escseq", "errorlist"].contains(id) {
            return true
        }
        return lexicalStyles?.values.contains(where: {
            $0.fontStyle & 3 != 0
        }) == true
            || terminalStyles?.values.contains(where: {
                $0.fontStyle & 3 != 0
            }) == true
    }
}

struct LanguageTokenStyle: Codable, Sendable {
    var foreground: String?
    var background: String?
    var fontStyle: Int
}

public struct LanguageRegistry: Sendable {
    public let languages: [LanguageDefinition]

    /// 业务作用：将完整校验后的自定义语言作为一个资源代次加入注册表。
    /// 参数说明:
    /// - definitions: 已完成解析且名称不冲突的 UDL 集合。
    /// 返回：新的完整注册表，旧快照仍有效。
    public func adding(_ definitions: [UDLDefinition]) -> LanguageRegistry {
        var result = languages
        for definition in definitions {
            result.removeAll {
                $0.id == definition.id
            }
            result.append(definition.languageDefinition())
        }
        return LanguageRegistry(languages: result)
    }

    /// 业务作用：构造一次性发布的不可变注册表。
    /// 参数说明:
    /// - languages: 完整有序语言资源。
    /// 返回：新的注册表。
    private init(languages: [LanguageDefinition]) {
        self.languages = languages
    }

    /// 业务作用：删除已明确移除的自定义资源身份，不触碰内置语言。
    /// 参数说明:
    /// - ids: 待移除的 UDL 标识。
    /// 返回：剩余语言的完整注册表。
    public func removing(_ ids: Set<String>) -> LanguageRegistry {
        LanguageRegistry(
            languages: languages.filter {
                !ids.contains($0.id)
            }
        )
    }

    /// 业务作用：载入随包语言，并让 HTML 从同一份已确认清单获取实际 JavaScript 词法规则。
    /// 参数说明:
    /// - directory: 注入的语言资源目录。
    /// 返回：完整注册表；主清单无法读取时失败，内嵌词法规则缺席时保留标记语言本身。
    public init(directory: URL) throws {
        var loaded = try JSONDecoder().decode(
            [LanguageDefinition].self,
            from: Data(contentsOf: directory.appendingPathComponent("registry.json"))
        )
        if let markup = loaded.firstIndex(where: { $0.id == "html" }),
            let script = loaded.first(where: { $0.id == "javascript.js" })
        {
            loaded[markup].embeddedScriptRules = ScriptRules(
                language: script,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        languages = loaded
    }

    /// 业务作用：按稳定标识查找语言规则，不依赖显示名称。
    /// 参数说明:
    /// - id: 官方标识或 UDL 标识。
    /// 返回：适用定义，不存在时为空。
    public func language(_ id: String) -> LanguageDefinition? {
        languages.first {
            $0.id == id
        }
    }

    /// 业务作用：以扩展名、特殊文件名和首行内容识别语言，手动选择由调用方优先保留。
    /// 参数说明:
    /// - filename: 实际文件名。
    /// - firstLine: 正文首行提示。
    /// - associations: 用户关联，优先于内置资源。
    /// 返回：匹配语言标识，未知扩展名仍以纯文本打开。
    public func detect(filename: String, firstLine: String, associations: [String: String] = [:]) -> String {
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension
        if let id = associations[name] ?? associations[ext] {
            return id
        }
        if let definition = languages.first(where: {
            $0.id.hasPrefix("udl:") && !$0.id.hasPrefix("udl:Markdown (preinstalled")
                && $0.extensions.contains(ext)
        }) {
            return definition.id
        }
        if let definition = languages.first(where: {
            $0.id != "searchResult"
                && $0.extensions.contains(
                    ext.isEmpty ? name.trimmingCharacters(in: CharacterSet(charactersIn: ".")) : ext
                )
        }) {
            return definition.id
        }
        let special: [String: String] = [
            "makefile": "makefile", "gnumakefile": "makefile", "cmakelists.txt": "cmake",
            "sconstruct": "python", "sconscript": "python", "wscript": "python", "rakefile": "ruby",
            "vagrantfile": "ruby", "crontab": "nncrontab", "pkgbuild": "bash", "apkbuild": "bash",
        ]
        if let id = special[name] {
            return id
        }
        if firstLine.hasPrefix("#!") {
            for (hint, id) in [
                ("python", "python"), ("ruby", "ruby"), ("perl", "perl"), ("node", "javascript.js"),
                ("sh", "bash"),
            ] {
                if firstLine.contains(hint) {
                    return id
                }
            }
        }
        if firstLine.hasPrefix("<?xml") {
            return "xml"
        }
        if firstLine.hasPrefix("<?php") {
            return "php"
        }
        if firstLine.lowercased().contains("<!doctype html") {
            return "html"
        }
        return "normal"
    }
}
