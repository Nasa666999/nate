import AppKit
import NateSyntax

@MainActor
public enum SyntaxPresentation {
    /// 业务作用：正文与独立输出采用相同语法颜色、字体及装饰，不让打印或导出另行猜测资源样式。
    /// 参数说明:
    /// - token: 当前固定语法片段及资源呈现参数。
    /// - font: 当前正文实际基础字体。
    /// - appearance: 来源编辑器真实外观，输出期间不重新读取活动窗口主题。
    /// - fontZoomAdjustment: 来源视图的点数缩放差值，只叠加到资源显式字号。
    /// 返回：在来源外观中固定的纯文本呈现属性，不包含附件、链接或正文编辑。
    public static func attributes(
        token: SyntaxToken,
        font: NSFont,
        appearance: NSAppearance,
        fontZoomAdjustment: CGFloat = 0
    )
        -> [NSAttributedString.Key: Any]
    {
        let styled = resolvedFont(
            name: token.fontName,
            size: token.fontSize,
            style: token.fontStyle,
            base: font,
            adjustment: fontZoomAdjustment
        )
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

    /// 业务作用：资源字体与点数独立生效，缺失字体只回退字族而不丢弃合法字号与装饰。
    /// 参数说明:
    /// - name: 本机字体名称，为空或不可用时继承基础字体。
    /// - size: 一至五百一十二点的资源字号，为空时继承基础点数。
    /// - style: 粗体与斜体装饰位，下划线由属性通道单独呈现。
    /// - base: 当前来源编辑器的实际字体。
    /// - adjustment: 实际视图的有界点数缩放，不重复叠加到已经缩放的继承字号。
    /// 返回：有界可用的原生字体；尚未通过词法验证的非法运行时字段不扩大字体请求。
    static func resolvedFont(
        name: String?,
        size: Int?,
        style: Int,
        base: NSFont,
        adjustment: CGFloat = 0
    ) -> NSFont {
        let delta = adjustment.isFinite && (-65...65).contains(adjustment) ? adjustment : 0
        let points =
            size.flatMap {
                (1...512).contains($0) ? max(1, CGFloat($0) + delta) : nil
            } ?? base.pointSize
        var font = points == base.pointSize ? base : NSFontManager.shared.convert(base, toSize: points)
        if let name, !name.isEmpty, name.utf8.count <= 256,
            name.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }), let explicit = NSFont(name: name, size: points)
        {
            font = explicit
        }
        if style & 1 != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if style & 2 != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
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
