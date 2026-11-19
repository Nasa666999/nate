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
                token.foreground.flatMap(ThemePalette.hexColor) ?? ThemePalette.color(token.kind),
                appearance: appearance
            ),
        ]
        if token.fontStyle & 4 != 0 {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
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
