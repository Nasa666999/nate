import Foundation
import NateCore

public struct FunctionListAssociations: Sendable {
    public let originalXML: Data
    public let userAssociations: [String: String]
    public let languageAssociations: [Int: String]
    public let ruleFilenames: [String: String]
    private let exactUserAssociations: [Data: String]
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

    /// 业务作用：独立校验 Notepad++ 函数列表关联，并保存引用原文件名及用户语言的精确 UTF-8 身份。
    /// 参数说明:
    /// - data: 完整的 overrideMap.xml 原字节。
    /// 返回：同一份有效映射；非法、重复、超量或不能限定到同层 XML 的关联整份拒绝。
    public init(data: Data) throws {
        let root = try ResourceXML.parse(data)
        guard root.name == "NotepadPlus",
            root.children.filter({ $0.name == "functionList" }).count == 1,
            let list = root.children.first(where: { $0.name == "functionList" }),
            list.children.filter({ $0.name == "associationMap" }).count == 1,
            let map = list.children.first(where: { $0.name == "associationMap" })
        else {
            throw NateError.message("函数列表 overrideMap 缺少 associationMap。")
        }
        var users: [String: String] = [:]
        var exactUsers: [Data: String] = [:]
        var languages: [Int: String] = [:]
        var filenames: [String: String] = [:]
        for association in map.children where association.name == "association" {
            guard let filename = association.attributes["id"], let key = Self.ruleKey(forFilename: filename)
            else {
                throw NateError.message("函数列表关联必须是同一目录内的规则 XML 文件名。")
            }
            // 同一规则可以服务多个语言，但两个大小写不同的文件名在不同卷上可能指向不同内容。
            guard filenames[key] == nil || filenames[key] == filename else {
                throw NateError.message("函数列表关联的规则文件名存在大小写冲突。")
            }
            filenames[key] = filename
            let name = association.attributes["userDefinedLangName"]
            let legacyID = association.attributes["langID"]
            // 一条规则只能有一个确切的语言身份，重复映射不能依赖 XML 文件内的顺序覆盖。
            if let name, !name.isEmpty, name.utf8.count <= 4092, legacyID == nil, users[name] == nil {
                users[name] = key
                exactUsers[Data(name.utf8)] = key
            }
            else if let legacyID, name == nil, legacyID.utf8.allSatisfy({ (48...57).contains($0) }),
                let number = Int(legacyID), Self.numericLanguages.indices.contains(number),
                Self.numericLanguages[number] != nil, languages[number] == nil
            {
                languages[number] = key
            }
            else {
                throw NateError.message("函数列表关联的语言标识缺失、重复或无效。")
            }
            guard languages.count + users.count <= 256, filenames.count <= 128 else {
                throw NateError.message("函数列表最多支持 256 条关联和 128 个不同规则文件。")
            }
        }
        self.originalXML = data
        userAssociations = users
        exactUserAssociations = exactUsers
        languageAssociations = languages
        ruleFilenames = filenames
    }

    /// 业务作用：实际关联与归档依赖使用同一规则文件名约束，确保名称只能表示单个同层资源。
    /// 参数说明:
    /// - filename: 关联或归档保存的完整规则文件名。
    /// 返回：标准化的规则键；目录、链接语法、自引用以及非法文件名没有规则键。
    public static func ruleKey(forFilename filename: String) -> String? {
        guard filename.utf8.count > 4, filename.utf8.count <= 255,
            !filename.hasPrefix("."), !filename.contains(".."), filename.hasSuffix(".xml"),
            filename.lowercased() != "overridemap.xml",
            filename.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 46, 95].contains($0)
            })
        else {
            return nil
        }
        return String(filename.dropLast(4)).lowercased()
    }

    /// 业务作用：把实际编辑语言映射到已经校验的规则名，内置语言使用固定协议编号。
    /// 参数说明:
    /// - language: 编辑器当前语言的稳定身份。
    /// - languageIndex: 调用者已知的官方语言编号；省略时使用当前语言标识查找。
    /// 返回：存在显式关联时提供规则键，UDL 仅接受原名称字节。
    public func ruleKey(for language: String, languageIndex: Int? = nil) -> String? {
        if language.hasPrefix("udl:") {
            return exactUserAssociations[Data(language.utf8.dropFirst(4))]
        }
        // 应用语言按界面名称排序，不能把显示顺序当作 Notepad++ 固定的协议编号。
        return (languageIndex ?? Self.numericLanguages.firstIndex(of: language)).flatMap {
            languageAssociations[$0]
        }
    }
}
