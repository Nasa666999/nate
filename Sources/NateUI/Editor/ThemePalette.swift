import AppKit
import NateSyntax

@MainActor
enum ThemePalette {
    /// 业务作用：提前排版时按真实视图外观解析动态颜色，缓存不携带其他窗口的深浅状态。
    /// 参数说明:
    /// - color: 系统或资源颜色。
    /// - appearance: 所属编辑视图的外观。
    /// 返回：已经在目标外观中解析的 RGB 颜色。
    static func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// 业务作用：语法样式跟随系统深浅主题，与正文状态独立。
    /// 参数说明:
    /// - kind: 语法分类。
    /// 返回：可辨识的系统适配颜色。
    static func color(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPurple
        case .string: return .systemGreen
        case .comment: return .secondaryLabelColor
        case .number: return .systemBlue
        case .heading: return .systemBlue
        case .tag: return .systemTeal
        case .punctuation: return .secondaryLabelColor
        case .text: return .textColor
        }
    }

    /// 业务作用：资源颜色只作为呈现值使用，非法格式继承主题。
    /// 参数说明:
    /// - hex: 六位 RGB 资源色。
    /// 返回：有效颜色或继承状态。
    static func hexColor(_ hex: String) -> NSColor? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1
        )
    }
}
