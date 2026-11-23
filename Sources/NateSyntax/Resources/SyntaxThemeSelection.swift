import Foundation
import NateCore

public enum SyntaxThemeSelection {
    /// 业务作用：整体正文与当前语言默认类别共同提供继承字体和底色，精确词法类别仍可单独覆盖。
    /// 参数说明:
    /// - theme: 所属视图固定的完整主题。
    /// - language: 当前稳定语言身份，为空时只采用通用正文样式。
    /// 返回：当前语言默认类别覆盖通用正文后的完整继承值。
    public static func defaults(
        theme: EditorThemeDefinition,
        language: String?
    ) -> EditorThemeStyle {
        let base = theme.kindStyles["text"] ?? EditorThemeStyle()
        guard let language, let style = theme.languageStyles[language]?["style:0"] else {
            return base
        }
        return style.merging(over: base)
    }

    /// 业务作用：主题先采用通用类别，再采用当前语言类别与完整词法或原生编号，避免跨语言借用颜色。
    /// 参数说明:
    /// - token: 原词法已经确认的完整范围及呈现字段。
    /// - theme: 本次显示或独立输出固定的主题。
    /// - language: 当前来源语言身份。
    /// 返回：只有明确主题字段参与的最终覆盖；UDL 原有明确属性优先于通用类别。
    public static func override(
        token: SyntaxToken,
        theme: EditorThemeDefinition,
        language: String?
    ) -> EditorThemeStyle {
        var result = theme.kindStyles[token.kind.rawValue] ?? EditorThemeStyle()
        if token.lexicalStyle.hasPrefix("udl:") {
            // UDL 的明确字面样式不能因通用类别配色丢失；逐语言明确覆盖仍可表达用户的新选择。
            if let preserved = try? EditorThemeStyle(
                foreground: token.foreground,
                background: token.background,
                fontName: token.fontName,
                fontSize: token.fontSize,
                fontStyle: token.fontStyle
            ) {
                result = preserved.merging(over: result)
            }
        }
        guard let language, let styles = theme.languageStyles[language] else {
            return result
        }
        for key in ["kind:" + token.kind.rawValue, token.lexicalStyle] {
            if let style = styles[key] {
                result = style.merging(over: result)
            }
        }
        if let native = token.nativeStyle, let style = styles["style:" + String(native)] {
            result = style.merging(over: result)
        }
        return result
    }
}
