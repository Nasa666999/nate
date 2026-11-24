import AppKit
import NateCore

@MainActor
enum NativeMonospaceGeometry {
    private struct TabProof: Hashable {
        let font: NSFont
        let width: Int
    }

    private static var advances: [NSFont: CGFloat] = [:]
    private static var rejected: Set<NSFont> = []
    private static var tabProofs: [TabProof: Bool] = [:]

    /// 业务作用：用真实原生段落复验每种起始余数，固定字体声明不足以单独证明制表坐标。
    /// 参数说明:
    /// - font: 完整窗口使用的实际字体。
    /// - width: 当前语言的实际 Tab 宽度。
    /// - advance: 已验证的单列原生步距。
    /// - appearance: 该视图实际采用的系统外观。
    /// 返回：所有原文端点均与真实原生制表位一致时为真；其余情况不使用长行快速布局。
    static func provesTabStops(
        _ font: NSFont,
        width: Int,
        advance: CGFloat,
        appearance: NSAppearance
    ) -> Bool {
        let key = TabProof(font: font, width: width)
        if let valid = tabProofs[key] {
            return valid
        }
        let text = PieceTree((0..<width).map { String(repeating: "x", count: $0) + "\t" }.joined() + "x")
        let range = ByteRange(0, text.byteCount)
        guard let columns = try? ASCIITabColumns(text: text, range: range, tabWidth: width) else {
            return false
        }
        let sample = LongLineWindow.project(
            snapshot: DocumentSnapshot(id: UUID(), revision: 0, text: text),
            range: range,
            font: font,
            appearance: appearance,
            width: CGFloat(columns.columnCount) * advance,
            theme: nil,
            language: nil,
            fontZoomAdjustment: 0,
            tabWidth: width
        )
        let origin = sample.caret(at: 0)
        let valid = (0...text.byteCount).allSatisfy { offset in
            let caret = sample.caret(at: offset)
            guard let column = columns.column(at: offset) else {
                return false
            }
            return abs(caret.minX - origin.minX - CGFloat(column) * advance) < 0.01
                && abs(caret.minY - origin.minY) < 0.01
        }
        if tabProofs.count >= 32 {
            tabProofs.removeAll()
        }
        tabProofs[key] = valid
        return valid
    }

    /// 业务作用：字体声明与全部已排版 ASCII 位置共同决定等宽资格，未排版片段不能提供步距证据。
    /// 参数说明:
    /// - font: 当前真实字体。
    /// - appearance: 当前真实视图外观。
    /// 返回：全部字符位置一致时提供真实步距，否则拒绝；证据缓存各最多三十二项。
    static func uniformAdvance(_ font: NSFont, appearance: NSAppearance) -> CGFloat? {
        if let value = advances[font] {
            return value
        }
        guard font.isFixedPitch, !rejected.contains(font) else {
            return nil
        }
        let text = PieceTree(String(decoding: Array(UInt8(32)...UInt8(126)), as: UTF8.self))
        // 未经布局管理器处理的片段没有有效坐标，先完成这个有界段落再读取真实字符位置。
        let sample = LineLayout(
            snapshot: DocumentSnapshot(
                id: UUID(),
                revision: 0,
                text: text
            ),
            range: ByteRange(0, text.byteCount),
            font: font,
            width: 1_000_000,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true
        )
        let origin = sample.caret(at: 0)
        let advance = sample.caret(at: 1).minX - origin.minX
        let valid =
            advance.isFinite && advance > 0 && advance <= 4096
            && (0...95).allSatisfy {
                let point = sample.caret(at: $0)
                return abs(point.minX - origin.minX - CGFloat($0) * advance) < 0.01
                    && abs(point.minY - origin.minY) < 0.01
            }
        if advances.count >= 32 {
            advances.removeAll()
        }
        if rejected.count >= 32 {
            rejected.removeAll()
        }
        if valid {
            advances[font] = advance
            return advance
        }
        rejected.insert(font)
        return nil
    }
}
