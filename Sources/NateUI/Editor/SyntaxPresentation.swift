import AppKit
import NateSyntax

@MainActor
public enum SyntaxPresentation {
    /// 业务作用：正文与独立输出采用相同语法颜色和字体装饰，不让打印或导出另行猜测资源样式。
    /// 参数说明:
    /// - token: 当前固定语法片段及资源呈现参数。
    /// - font: 当前正文实际基础字体。
    /// - appearance: 来源编辑器真实外观，输出期间不重新读取活动窗口主题。
    /// 返回：在来源外观中固定的纯文本呈现属性，不包含附件、链接或正文编辑。
    public static func attributes(token: SyntaxToken, font: NSFont, appearance: NSAppearance)
        -> [NSAttributedString.Key: Any]
    {
        var styled = font
        if token.fontStyle & 1 != 0 {
            styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask)
        }
        if token.fontStyle & 2 != 0 {
            styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
        }
        var result: [NSAttributedString.Key: Any] = [
            .font: styled,
            .foregroundColor: ThemePalette.resolved(
                token.foreground.flatMap(ThemePalette.hexColor) ?? lexicalColor(token),
                appearance: appearance
            ),
        ]
        if let background = token.background.flatMap(ThemePalette.hexColor) {
            result[.backgroundColor] = ThemePalette.resolved(background, appearance: appearance)
        }
        if let adapted = NativeSyntaxContrast.colors(token: token, appearance: appearance) {
            result[.foregroundColor] = adapted.foreground
            result[.backgroundColor] = adapted.background
        }
        if token.fontStyle & 4 != 0 {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    /// 业务作用：内置词法的属性、类型、转义与非法片段使用可辨颜色，不改变其原有结构作用域。
    /// 参数说明:
    /// - token: 已完成词法分析的原始片段。
    /// 返回：动态系统颜色，由调用方在来源外观中解析。
    private static func lexicalColor(_ token: SyntaxToken) -> NSColor {
        switch token.lexicalStyle {
        case "json:property", "c:type", "c:documentationKeyword":
            return .systemTeal
        case "json:escape", "c:escape":
            return .systemOrange
        case "json:invalid", "c:invalid", "c:documentationInvalid":
            return .systemRed
        default:
            return ThemePalette.color(token.kind)
        }
    }

    /// 业务作用：输出固定来源视图的动态系统颜色，不随打印面板的深浅外观变化重新解释。
    /// 参数说明:
    /// - color: 当前正文的实际系统颜色。
    /// - appearance: 来源编辑器外观。
    /// 返回：已经解析的固定 RGB 颜色。
    public static func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        ThemePalette.resolved(color, appearance: appearance)
    }
}
