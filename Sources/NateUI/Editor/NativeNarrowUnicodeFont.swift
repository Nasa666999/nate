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
        return aligns(
            units,
            columns: Array(0...units.count),
            font: font,
            advance: advance,
            appearance: appearance
        )
    }

    /// 业务作用：用实际原文组合复验字形的占列及簇内插入点，裁剪后仍按同一字形宽度平移。
    /// 参数说明:
    /// - pairs: 同一长行中已确认为完整组合的基本字母与附标。
    /// - font: 当前主题和缩放后的实际基础字体。
    /// - advance: 实际 ASCII 字形的单列步距。
    /// - appearance: 当前原生窗口外观。
    /// - tabWidth: 含真实 Tab 的原文采用的列宽，无 Tab 时为空。
    /// 返回：组合字形、簇内位置和制表停靠与实际 TextKit 一致时为真。
    static func provesCombining(
        _ pairs: [UInt32],
        font: NSFont,
        advance: CGFloat,
        appearance: NSAppearance,
        tabWidth: Int? = nil
    ) -> Bool {
        var units: [UInt16] = []
        var columns = [0]
        var column = 0
        for pair in pairs {
            units += [65, UInt16(pair >> 16), UInt16(truncatingIfNeeded: pair), 97]
            columns += [column + 1, column + 2, column + 2, column + 3]
            column += 3
            if let tabWidth {
                units.append(9)
                column += tabWidth - column % tabWidth
                columns.append(column)
            }
        }
        return !pairs.isEmpty
            && aligns(
                units,
                columns: columns,
                font: font,
                advance: advance,
                appearance: appearance,
                tabWidth: tabWidth ?? 4
            )
    }

    /// 业务作用：只在样本文字的每个真实插入点都落在预期网格时授予长行前缀坐标。
    /// 参数说明:
    /// - units: 样本的原始 UTF-16 正文。
    /// - columns: 每个 UTF-16 端点对应的实际预期字形列。
    /// - font: 当前使用的原生基础字体。
    /// - advance: 实际单列步距。
    /// - appearance: 当前原生窗口外观。
    /// - tabWidth: 样本采用的实际制表间隔。
    /// 返回：完整段落等距且高度一致时为真。
    private static func aligns(
        _ units: [UInt16],
        columns: [Int],
        font: NSFont,
        advance: CGFloat,
        appearance: NSAppearance,
        tabWidth: Int = 4
    ) -> Bool {
        let text = PieceTree(String(decoding: units, as: UTF16.self))
        let layout = LineLayout(
            snapshot: DocumentSnapshot(id: UUID(), revision: 0, text: text),
            range: ByteRange(0, text.byteCount),
            font: font,
            width: CGFloat(columns.last ?? units.count) * advance + 64,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true,
            tabWidth: tabWidth
        )
        let start = layout.caret(at: 0)
        return layout.isSingleVisualLine && layout.characterCount == units.count
            && columns.enumerated().allSatisfy { index, column in
                let point = layout.caret(at: index)
                return abs(point.minX - start.minX - CGFloat(column) * advance) < 0.02
                    && abs(point.minY - start.minY) < 0.01
            }
    }
}
