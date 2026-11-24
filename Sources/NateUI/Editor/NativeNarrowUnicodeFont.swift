import AppKit
import CoreText
import NateCore

@MainActor
enum NativeNarrowUnicodeFont {
    /// 业务作用：实际出现的独立字母必须由当前基础字体直接覆盖，并在真实 TextKit 中对齐同一等宽网格。
    /// 参数说明:
    /// - scalars: 同一完整原始长行已经确认的非 ASCII 标量集合。
    /// - font: 当前主题和缩放后的实际基础字体。
    /// - advance: 真实 ASCII 样本确认的单列步距。
    /// - appearance: 当前窗口实际外观。
    /// 返回：字体覆盖和局部原生插入点同时成立时为真，任一字体回退或不等距时保留原段落门禁。
    static func proves(
        _ scalars: [UInt16],
        font: NSFont,
        advance: CGFloat,
        appearance: NSAppearance
    ) -> Bool {
        guard !scalars.isEmpty else {
            return false
        }
        var glyphs = [CGGlyph](repeating: 0, count: scalars.count)
        var advances = [CGSize](repeating: .zero, count: scalars.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, scalars, &glyphs, scalars.count) else {
            return false
        }
        _ = CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
        guard glyphs.allSatisfy({ $0 != 0 }),
            advances.allSatisfy({ abs($0.width - advance) < 0.01 && $0.height == 0 })
        else {
            return false
        }
        // 独立字形度量仍需经 TextKit 的实际字体选择和字符位置复验，才能使用完整行前缀距离。
        let units = scalars.flatMap { [UInt16(65), $0, UInt16(97)] }
        let text = PieceTree(String(decoding: units, as: UTF16.self))
        let layout = LineLayout(
            snapshot: DocumentSnapshot(id: UUID(), revision: 0, text: text),
            range: ByteRange(0, text.byteCount),
            font: font,
            width: CGFloat(units.count) * advance + 64,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true
        )
        let start = layout.caret(at: 0)
        return layout.isSingleVisualLine && layout.characterCount == units.count
            && (0...units.count).allSatisfy { index in
                let point = layout.caret(at: index)
                return abs(point.minX - start.minX - CGFloat(index) * advance) < 0.02
                    && abs(point.minY - start.minY) < 0.01
            }
    }
}
