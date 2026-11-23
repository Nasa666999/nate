import AppKit
import NateCore
import NateSyntax

@MainActor
enum EditorThemePresentation {
    private struct ColorKey: Hashable {
        let foreground: [Double]
        let background: [Double]
        let text: [Double]
    }
    private static var colors: [ColorKey: NSColor] = [:]

    /// 业务作用：主题整体颜色只在来源视图中解析，缺省项沿用该视图的系统外观。
    /// 参数说明:
    /// - role: 当前整体呈现角色。
    /// - fallback: 没有明确主题字段时的原有颜色。
    /// - theme: 来源视图已固定的完整主题。
    /// - appearance: 来源视图真实系统外观。
    /// - language: 当前来源语言身份，用于默认类别的继承色。
    /// 返回：固定 sRGB 颜色；继承正文色在明确主题底色上适配对比，不读取其它活动窗口。
    static func color(
        _ role: EditorThemeColorRole,
        fallback: NSColor,
        theme: EditorThemeDefinition?,
        appearance: NSAppearance,
        language: String? = nil
    ) -> NSColor {
        var value = theme?.colors[role.rawValue]
        var canvas = theme?.colors["background"]
        if value == nil, let theme {
            let defaults = SyntaxThemeSelection.defaults(theme: theme, language: language)
            canvas = canvas ?? defaults.background
            if role == .foreground {
                value = defaults.foreground
            }
            else if role == .background {
                value = defaults.background
            }
        }
        let selected = value.flatMap(ThemePalette.hexColor) ?? fallback
        let resolved = ThemePalette.resolved(selected, appearance: appearance)
        if role == .foreground, value == nil, let background = canvas.flatMap(ThemePalette.hexColor) {
            return readable(resolved, on: background, text: resolved)
        }
        return resolved
    }

    /// 业务作用：没有词法范围的正文和末行仍采用同一主题默认字体，字号缩放只叠加一次。
    /// 参数说明:
    /// - font: 原视图基础字体及现有缩放。
    /// - theme: 来源视图固定主题。
    /// - language: 当前来源语言身份。
    /// - adjustment: 来源视图明确的字号缩放差值。
    /// 返回：主题默认字体或原字体；不改变用户保存的字体偏好。
    static func baseFont(
        _ font: NSFont,
        theme: EditorThemeDefinition?,
        language: String?,
        adjustment: CGFloat
    ) -> NSFont {
        guard let theme else {
            return font
        }
        let style = SyntaxThemeSelection.defaults(theme: theme, language: language)
        return SyntaxPresentation.resolvedFont(
            name: style.fontName,
            size: style.fontSize,
            style: style.fontStyle ?? 0,
            base: font,
            adjustment: adjustment
        )
    }

    /// 业务作用：完整主题覆盖与原词法属性组合后交给统一呈现，专用底色与 UDL 明确字段保持独立优先级。
    /// 参数说明:
    /// - attributes: 已按原始资源和来源外观解析的基础属性。
    /// - token: 原词法的完整范围与结构身份。
    /// - font: 当前来源基础字体。
    /// - adjustment: 当前明确的字体缩放差值。
    /// - appearance: 来源外观。
    /// - theme: 当前完整主题。
    /// - language: 当前稳定语言身份。
    /// 返回：仅呈现字段发生变化的完整原生属性，不授予正文或历史写入权。
    static func applying(
        _ attributes: [NSAttributedString.Key: Any],
        token: SyntaxToken,
        font: NSFont,
        adjustment: CGFloat,
        appearance: NSAppearance,
        theme: EditorThemeDefinition,
        language: String?
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let defaults = SyntaxThemeSelection.defaults(theme: theme, language: language)
        let selected = SyntaxThemeSelection.override(token: token, theme: theme, language: language)
        result[.font] = SyntaxPresentation.resolvedFont(
            name: selected.fontName ?? token.fontName ?? defaults.fontName,
            size: selected.fontSize ?? token.fontSize ?? defaults.fontSize,
            style: selected.fontStyle ?? token.fontStyle,
            base: font,
            adjustment: adjustment
        )
        let decoration = selected.fontStyle ?? token.fontStyle
        result[.underlineStyle] = decoration & 4 != 0 ? NSUnderlineStyle.single.rawValue : 0
        let userDefined = token.lexicalStyle.hasPrefix("udl:")
        let canvas = theme.colors["background"] ?? defaults.background
        let text = theme.colors["foreground"] ?? defaults.foreground
        if let canvas, let background = ThemePalette.hexColor(canvas),
            !userDefined, token.background == nil || token.background?.uppercased() == "#FFFFFF"
        {
            result[.backgroundColor] = background
            if selected.foreground == nil,
                let raw = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
            {
                let normal =
                    text.flatMap(ThemePalette.hexColor)
                    ?? color(
                        .foreground,
                        fallback: .textColor,
                        theme: theme,
                        appearance: appearance
                    )
                result[.foregroundColor] = readable(raw, on: background, text: normal)
            }
        }
        if selected.foreground == nil, !userDefined,
            token.kind == .text || token.foreground?.uppercased() == "#000000",
            let text, let foreground = ThemePalette.hexColor(text)
        {
            result[.foregroundColor] = foreground
        }
        if let foreground = selected.foreground.flatMap(ThemePalette.hexColor) {
            result[.foregroundColor] = foreground
        }
        if let background = selected.background.flatMap(ThemePalette.hexColor) {
            result[.backgroundColor] = background
        }
        return result
    }

    /// 业务作用：主题底色改变后重新确认内置默认前景的对比，不能复用此前系统深浅外观的适配值。
    /// 参数说明:
    /// - original: 原生资源的固定前景。
    /// - background: 当前明确主题底色。
    /// - text: 当前明确正文色。
    /// 返回：已有对比足够时保持原色，否则向可读的黑白端点有界调整；缓存最多 512 项。
    private static func readable(_ original: NSColor, on background: NSColor, text: NSColor) -> NSColor {
        let key = ColorKey(
            foreground: NativeSyntaxContrast.components(original),
            background: NativeSyntaxContrast.components(background),
            text: NativeSyntaxContrast.components(text)
        )
        if let saved = colors[key] {
            return saved
        }
        let base = NativeSyntaxContrast.packed(original) == 0 ? text : original
        var selected = base
        if NativeSyntaxContrast.contrast(base, background) < 4.5 {
            let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            let target =
                NativeSyntaxContrast.contrast(white, background)
                    >= NativeSyntaxContrast.contrast(black, background) ? white : black
            var lower = 0.0, upper = 1.0
            for _ in 0..<20 {
                let middle = (lower + upper) / 2
                let candidate = mixed(base, target: target, amount: middle)
                if NativeSyntaxContrast.contrast(candidate, background) >= 4.5 {
                    upper = middle
                }
                else {
                    lower = middle
                }
            }
            selected = mixed(base, target: target, amount: upper)
        }
        if colors.count >= 512 {
            colors.removeAll(keepingCapacity: true)
        }
        colors[key] = selected
        return selected
    }

    /// 业务作用：对比调整只沿实际原色和选定黑白端点插值，保持词法类别间的原始色彩区别。
    /// 参数说明:
    /// - original: 已解析原色。
    /// - target: 当前底色上更可读的黑白端点。
    /// - amount: 零至一的混合比例。
    /// 返回：固定 sRGB 颜色，不携带动态系统状态。
    private static func mixed(_ original: NSColor, target: NSColor, amount: Double) -> NSColor {
        NSColor(
            srgbRed: original.redComponent + (target.redComponent - original.redComponent) * amount,
            green: original.greenComponent + (target.greenComponent - original.greenComponent) * amount,
            blue: original.blueComponent + (target.blueComponent - original.blueComponent) * amount,
            alpha: 1
        )
    }
}
