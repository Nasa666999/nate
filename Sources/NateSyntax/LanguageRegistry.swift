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
}

public struct LanguageRegistry: Sendable {
    public let languages: [LanguageDefinition]

    /// 业务作用：从随包语言清单载入所有官方模式和预装补充语言。
    /// 参数说明:
    /// - directory: 注入的语言资源目录。
    /// 返回：完整注册表；资源缺失明确失败。
    public init(directory: URL) throws {
        languages = try JSONDecoder().decode(
            [LanguageDefinition].self,
            from: Data(contentsOf: directory.appendingPathComponent("registry.json"))
        )
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
