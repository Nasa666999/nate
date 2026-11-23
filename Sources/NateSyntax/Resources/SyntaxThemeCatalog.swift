import Foundation

public struct SyntaxThemeChoice: Sendable, Equatable {
    public let key: String
    public let name: String

    /// 业务作用：主题目录分别保留稳定编辑身份和用户可见名称，标签变化不重定向样式覆盖。
    /// 参数说明:
    /// - key: 当前完整类别、整体角色或词法身份。
    /// - name: 当前界面显示名称。
    /// 返回：只读目录项，不授予资源或正文写入权。
    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public enum SyntaxThemeCatalog {
    /// 业务作用：所有语言都有明确类别覆盖，已具有原生类别的语言另提供独立数字样式。
    /// 参数说明:
    /// - language: 当前内置语言，为空时只提供通用类别。
    /// - userLanguage: 当前独立用户语言，其真实样式名称优先。
    /// - additional: 当前主题已经保留的精确身份，尚无对应资源时仍可查看和编辑。
    /// - names: 对应原生数字类别的资源名称，缺失时仍明确显示编号。
    /// 返回：稳定且唯一的可编辑身份目录，不从当前颜色推断类别。
    public static func choices(
        language: LanguageDefinition?,
        userLanguage: UDLDefinition? = nil,
        additional: Set<String> = [],
        names: [String: String] = [:]
    ) -> [SyntaxThemeChoice] {
        let kinds = [
            ("text", "正文与标识符"), ("keyword", "关键字与类型"), ("string", "字符串与字符"),
            ("comment", "注释"), ("number", "数字"), ("punctuation", "操作符与标点"),
            ("heading", "标题"), ("tag", "标签"),
        ]
        var result = kinds.map {
            SyntaxThemeChoice(key: language == nil ? $0.0 : "kind:" + $0.0, name: $0.1)
        }
        var known = Set(result.map(\.key))
        if let userLanguage {
            for name in userLanguage.styles.keys.sorted() {
                let key = "udl:" + name
                result.append(SyntaxThemeChoice(key: key, name: name))
                known.insert(key)
            }
        }
        else if let language {
            var numbers = Set(language.lexicalStyles?.keys.compactMap(UInt8.init) ?? [])
            if language.usesSharedCLexer {
                numbers.formUnion(UInt8(0)...UInt8(27))
            }
            if language.id == "python" {
                numbers.formUnion(UInt8(0)...UInt8(19))
            }
            for identifier in numbers.sorted() {
                let key = "style:" + String(identifier)
                result.append(
                    SyntaxThemeChoice(
                        key: key,
                        name: names[String(identifier)] ?? "原生样式 " + String(identifier)
                    )
                )
                known.insert(key)
            }
        }
        for key in additional.sorted() where !known.contains(key) {
            let native = key.hasPrefix("style:") ? names[String(key.dropFirst(6))] : nil
            result.append(SyntaxThemeChoice(key: key, name: native ?? key))
        }
        return result
    }
}
