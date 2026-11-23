import Foundation
import NateCore

extension ScriptRules {
    /// 业务作用：共享扫描器的语义片段按当前脚本语言映射到真实样式，颜色与字体不能沿用其它语言。
    /// 参数说明:
    /// - style: 共享词法已经确认的片段身份。
    /// - state: 当前片段所属的注释、预处理或引号状态。
    /// 返回：原生数字类别及完整样式；未知身份或缺少样式时拒绝整次高亮。
    func presentation(_ style: String, state: CLexicalState) throws -> (Int, LanguageTokenStyle) {
        let identifier: Int
        switch style {
        case "text", "continuation":
            identifier = 0
        case "comment":
            identifier = state.scriptPreprocessorComment ? 23 : (state.lineComment ? 2 : 1)
        case "documentation":
            identifier = state.scriptPreprocessorComment ? 24 : (state.lineComment ? 15 : 3)
        case "number":
            identifier = 4
        case "keyword":
            identifier = 5
        case "string":
            identifier = 6
        case "character":
            identifier = 7
        case "preprocessor", "header":
            identifier = 9
        case "punctuation":
            identifier = 10
        case "identifier":
            identifier = 11
        case "invalid":
            identifier = 12
        case "verbatim":
            identifier = 13
        case "regex":
            identifier = 14
        case "type":
            identifier = 16
        case "documentationKeyword":
            identifier = 17
        case "documentationInvalid":
            identifier = 18
        case "globalClass":
            identifier = 19
        case "raw":
            identifier = 20
        case "userLiteral":
            identifier = 25
        case "escape":
            identifier = state.quote == 39 ? 7 : 6
        default:
            guard style.hasPrefix("substyle"), let value = Int(style.dropFirst(8)),
                (128...135).contains(value)
            else {
                throw NateError.message("脚本高亮遇到未定义的原生类别。")
            }
            identifier = value
        }
        guard let attributes = styles[String(identifier)] else {
            throw NateError.message("脚本高亮缺少完整样式属性。")
        }
        return (identifier, attributes)
    }
}

extension CLexing {
    /// 业务作用：脚本词元将原生类别与当前资源属性一起固定，其它共享语言保留原有语义身份。
    /// 参数说明:
    /// - range: 当前片段已经确认的完整原字节范围。
    /// - kind: 字面、注释、数字或代码的结构身份。
    /// - style: 已经确认的共享词法身份。
    /// 返回：绑定当前资源的完整片段；缺少对应类别或属性时抛错，不发布部分呈现。
    func makeToken(range: ByteRange, kind: SyntaxKind, style: String) throws -> SyntaxToken {
        guard let scriptRules else {
            return SyntaxToken(
                range: range,
                kind: kind,
                lexicalStyle: "c:" + style,
                nativeStyle: CThemeStyleIdentity.nativeID(style, state: state)
            )
        }
        let (identifier, attributes) = try scriptRules.presentation(style, state: state)
        return SyntaxToken(
            range: range,
            kind: kind,
            foreground: attributes.foreground,
            background: attributes.background,
            fontStyle: attributes.fontStyle,
            lexicalStyle: "script:" + String(identifier)
        )
    }

    /// 业务作用：脚本文档命令使用原字节词表，不把 Unicode 等价拼写冒充用户声明。
    /// 参数说明:
    /// - value: 当前完整候选或带标记的候选。
    /// 返回：当前语言的明确文档词表包含该原字节名称时为真。
    func containsDocumentation(_ value: String) -> Bool {
        if let scriptRules {
            return scriptRules.groups[2].contains(Data(value.utf8))
        }
        return documentationKeywords.contains(value)
    }
}
