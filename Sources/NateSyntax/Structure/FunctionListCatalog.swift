import Foundation
import NateCore

public struct FunctionListCatalog: Sendable {
    public let generation = UUID()
    public let definitions: [String: FunctionListDefinition]
    public let userAssociations: [String: String]
    public let languageAssociations: [Int: String]
    private static let numericLanguages: [String?] = [
        "normal", "php", "c", "cpp", "cs", "objc", "java", "rc",
        "html", "xml", "makefile", "pascal", "batch", "ini", "nfo", nil,
        "asp", "sql", "vb", "javascript", "css", "perl", "python", "lua",
        "tex", "fortran", "bash", "actionscript", "nsis", "tcl", "lisp", "scheme",
        "asm", "diff", "props", "postscript", "ruby", "smalltalk", "vhdl", "kix",
        "autoit", "caml", "ada", "verilog", "matlab", "haskell", "inno", nil,
        "cmake", "yaml", "cobol", "gui4cli", "d", "powershell", "r", "jsp",
        "coffeescript", "json", "javascript.js", "fortran77", "baanc", "srec", "ihex", "tehex",
        "swift", "asn1", "avs", "blitzbasic", "purebasic", "freebasic", "csound", "erlang",
        "escript", "forth", "latex", "mmixal", "nim", "nncrontab", "oscript", "rebol",
        "registry", "rust", "spice", "txt2tags", "visualprolog", "typescript", "json5", "mssql",
        "gdscript", "hollywood", "go", "raku", "toml", "sas", "errorlist", "escseq",
        "fcST",
    ]

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
                    root.children.filter({ $0.name == "functionList" }).count == 1,
                    let list = root.children.first(where: {
                        $0.name == "functionList"
                    }),
                    list.children.filter({ $0.name == "associationMap" }).count == 1,
                    let map = list.children.first(where: {
                        $0.name == "associationMap"
                    })
                else {
                    throw NateError.message("函数列表 overrideMap 缺少 associationMap。")
                }
                for association in map.children where association.name == "association" {
                    guard let filename = association.attributes["id"],
                        filename.utf8.count > 4, filename.utf8.count <= 255,
                        !filename.contains(".."), filename.hasSuffix(".xml"),
                        filename.utf8.allSatisfy({
                            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                                || [45, 46, 95].contains($0)
                        })
                    else {
                        throw NateError.message("函数列表关联必须是同一目录内的 XML 文件名。")
                    }
                    let id = String(filename.dropLast(4)).lowercased()
                    let name = association.attributes["userDefinedLangName"]
                    let legacyID = association.attributes["langID"]
                    // 一条规则只能有一个确切的语言身份，重复映射不能依赖 XML 文件内的顺序覆盖。
                    if let name, !name.isEmpty, legacyID == nil, users[name] == nil {
                        users[name] = id
                    }
                    else if let legacyID, name == nil, let number = Int(legacyID),
                        Self.numericLanguages.indices.contains(number), Self.numericLanguages[number] != nil,
                        languages[number] == nil
                    {
                        languages[number] = id
                    }
                    else {
                        throw NateError.message("函数列表关联的语言标识缺失、重复或无效。")
                    }
                }
            }
            else {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                guard definitions[key] == nil else {
                    throw NateError.message("函数列表规则文件名存在重复。")
                }
                definitions[key] = try FunctionListDefinition(data: data)
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
        // 应用语言按界面名称排序，不能把显示顺序当作 Notepad++ 固定的协议编号。
        if let index = languageIndex ?? Self.numericLanguages.firstIndex(of: language),
            let override = languageAssociations[index]
        {
            return definitions[override]
        }
        return definitions[language.lowercased()]
    }
}
