import AppKit
import CoreText
import NateCore

@MainActor
struct NativeHanLineFont {
    let font: NSFont
    let advance: CGFloat
    private static var measured: [NSFont: Self] = [:]
    private static var rejected: Set<NSFont> = []

    /// 业务作用：使用当前字体级联选择真实汉字字体，并确认基本汉字与明确全角标点的全部字形均具有同一原生步距。
    /// 参数说明:
    /// - base: 当前主题、语言与缩放实际使用的基础字体。
    /// 返回：该级联支持完整基本汉字及固定水平方向时提供真实度量，否则拒绝安全长行投影。
    static func resolve(from base: NSFont) -> Self? {
        if let value = measured[base] {
            return value
        }
        guard !rejected.contains(base) else {
            return nil
        }
        let characters = Array(UInt16(0x4E00)...UInt16(0x9FFF)) + PlainHanLine.fullwidthPunctuation
        let sample = "中" as CFString
        let fallback = CTFontCreateForString(base as CTFont, sample, CFRange(location: 0, length: 1))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        let valid = CTFontGetGlyphsForCharacters(fallback, characters, &glyphs, characters.count)
        if valid {
            _ = CTFontGetAdvancesForGlyphs(fallback, .horizontal, glyphs, &advances, glyphs.count)
        }
        let advance = advances[0].width
        guard valid, advance.isFinite, advance > 0, advance <= 4096,
            glyphs.allSatisfy({ $0 != 0 }),
            advances.allSatisfy({ $0.width == advance && $0.height == 0 })
        else {
            if rejected.count >= 32 {
                rejected.removeAll()
            }
            rejected.insert(base)
            return nil
        }
        let result = Self(font: fallback as NSFont, advance: advance)
        if measured.count >= 32 {
            measured.removeAll()
        }
        measured[base] = result
        return result
    }

    /// 业务作用：有界原生窗口中的基本汉字固定采用度量时确认的真实级联字体，避免窗口边界改变回退字体。
    /// 参数说明:
    /// - value: 已读取的单个有界窗口属性字符串，其 UTF-16 坐标对应完整原字节。
    /// 返回：仅改变连续全角字形的字体属性，字符串与其余样式保持。
    func apply(to value: NSMutableAttributedString) {
        var start: Int?
        for (index, scalar) in value.string.utf16.enumerated() {
            if PlainHanLine.usesHanFont(scalar) {
                start = start ?? index
            }
            else if let lower = start {
                value.addAttribute(.font, value: font, range: NSRange(location: lower, length: index - lower))
                start = nil
            }
        }
        if let start {
            value.addAttribute(
                .font,
                value: font,
                range: NSRange(location: start, length: value.length - start)
            )
        }
    }
}
