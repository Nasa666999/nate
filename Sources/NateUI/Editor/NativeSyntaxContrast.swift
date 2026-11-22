import AppKit
import NateSyntax

@MainActor
enum NativeSyntaxContrast {
    struct Key: Hashable {
        let foreground: String
        let background: [Double]
        let text: [Double]
    }

    static var cache: [Key: NSColor] = [:]
    static let languages: Set<String> = [
        "ini", "props", "diff", "makefile", "registry", "ihex", "srec", "tehex", "tex", "latex", "lisp",
        "scheme", "rust",
    ]

    /// 业务作用：内置浅色样式的默认白底在深色外观中继承编辑器底色，默认文字与语法色保持可读。
    /// 参数说明:
    /// - token: 已确认的内置词法身份与原始资源颜色。
    /// - appearance: 来源编辑器固定外观。
    /// 返回：仅默认白底的深色适配颜色；专用底色、终端、UDL 或缺少颜色时保持原资源通道。
    static func colors(token: SyntaxToken, appearance: NSAppearance)
        -> (foreground: NSColor, background: NSColor)?
    {
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            token.lexicalStyle.utf8.count <= 32,
            let separator = token.lexicalStyle.firstIndex(of: ":"),
            languages.contains(String(token.lexicalStyle[..<separator])),
            Int(token.lexicalStyle[token.lexicalStyle.index(after: separator)...]) != nil,
            let foreground = token.foreground,
            let original = ThemePalette.hexColor(foreground)?.usingColorSpace(.sRGB),
            let sourceBackground = token.background.flatMap(ThemePalette.hexColor)?.usingColorSpace(.sRGB),
            packed(sourceBackground) == 0xFF_FFFF,
            let background = ThemePalette.resolved(.textBackgroundColor, appearance: appearance)
                .usingColorSpace(.sRGB),
            let text = ThemePalette.resolved(.textColor, appearance: appearance).usingColorSpace(.sRGB)
        else {
            return nil
        }
        let key = Key(
            foreground: foreground,
            background: components(background),
            text: components(text)
        )
        if let color = cache[key] {
            return (color, background)
        }
        let color: NSColor
        if packed(original) == 0, contrast(text, background) >= 4.5 {
            color = text
        }
        else {
            color = readable(original, on: background)
        }
        if cache.count >= 512 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = color
        return (color, background)
    }

    /// 业务作用：缓存保留实际外观的完整颜色分量，避免量化后复用略低于对比要求的结果。
    /// 参数说明:
    /// - color: 已在 sRGB 中解析的颜色。
    /// 返回：实际颜色的三个分量，用于独立外观缓存身份。
    static func components(_ color: NSColor) -> [Double] {
        [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }

    /// 业务作用：六位资源色的黑白锚点以原八位通道识别，不按文字类别猜测默认底色。
    /// 参数说明:
    /// - color: 已在 sRGB 中解析的颜色。
    /// 返回：三个八位颜色通道的稳定身份。
    static func packed(_ color: NSColor) -> UInt32 {
        let red = UInt32((max(0, min(1, color.redComponent)) * 255).rounded())
        let green = UInt32((max(0, min(1, color.greenComponent)) * 255).rounded())
        let blue = UInt32((max(0, min(1, color.blueComponent)) * 255).rounded())
        return red << 16 | green << 8 | blue
    }

    /// 业务作用：颜色可读性以线性光相对亮度计算，避免直接比较编码通道误判深色文字。
    /// 参数说明:
    /// - color: 已解析的 sRGB 颜色。
    /// 返回：零至一的相对亮度。
    static func luminance(_ color: NSColor) -> Double {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
            value -> Double in
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    /// 业务作用：默认深色底上的普通字号文字采用固定亮度对比要求，不依赖字体粗细放宽。
    /// 参数说明:
    /// - foreground: 当前候选文字颜色。
    /// - background: 当前来源编辑器底色。
    /// 返回：两种颜色的亮度对比值。
    static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// 业务作用：仅对不足的原始颜色增加明度，保留已有可读颜色并限制每个新颜色的计算量。
    /// 参数说明:
    /// - original: 原始资源前景。
    /// - background: 来源编辑器的深色底色。
    /// 返回：对比至少 4.5 的颜色，已有足够对比时逐值保留原色。
    static func readable(_ original: NSColor, on background: NSColor) -> NSColor {
        if contrast(original, background) >= 4.5 {
            return original
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<20 {
            let middle = (lower + upper) / 2
            let candidate = mixed(original, amount: middle)
            if contrast(candidate, background) >= 4.5 {
                upper = middle
            }
            else {
                lower = middle
            }
        }
        return mixed(original, amount: upper)
    }

    /// 业务作用：在原始通道与白色间确定性插值，避免按词法类别丢掉原始色彩区别。
    /// 参数说明:
    /// - original: 原始资源前景。
    /// - amount: 零至一的明度混合比例。
    /// 返回：固定 sRGB 颜色，不携带动态外观或全局状态。
    static func mixed(_ original: NSColor, amount: Double) -> NSColor {
        NSColor(
            srgbRed: original.redComponent + (1 - original.redComponent) * amount,
            green: original.greenComponent + (1 - original.greenComponent) * amount,
            blue: original.blueComponent + (1 - original.blueComponent) * amount,
            alpha: 1
        )
    }
}
