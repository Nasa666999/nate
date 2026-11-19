import AppKit
import NateCore

@MainActor
final class ASCIILineWindow {
    let snapshot: DocumentSnapshot
    let range: ByteRange
    let advance: CGFloat
    let font: NSFont
    let appearance: NSAppearance
    private(set) var renderedRange: ByteRange
    private var native: LineLayout
    private static var advances: [NSFont: CGFloat] = [:]
    private static var rejected: Set<NSFont> = []

    var rendered: NSAttributedString {
        native.content.rendered
    }
    var content: EditorContentManager {
        native.content
    }
    var manager: NSTextLayoutManager {
        native.manager
    }
    var height: CGFloat {
        native.height
    }
    var width: CGFloat {
        CGFloat(range.count) * advance
    }
    private var offsetX: CGFloat {
        CGFloat(renderedRange.lower - range.lower) * advance
    }

    /// 业务作用：完整可打印 ASCII 与实际原生等宽证据均成立时，才用有界原生段落替代整条长行。
    /// 参数说明:
    /// - snapshot: 唯一正文的固定快照。
    /// - range: 完整逻辑行原字节范围。
    /// - font: 当前视图真实字体。
    /// - appearance: 当前视图实际外观。
    /// 返回：符合安全条件时保留有界原生窗口，否则不授予等宽坐标资格。
    init?(snapshot: DocumentSnapshot, range: ByteRange, font: NSFont, appearance: NSAppearance) {
        // 整行字节与原生步距必须同时得到证明，缺少任一证据都不能沿等宽前缀计算正文坐标。
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= snapshot.text.byteCount,
            range.count >= EditorNativeLayoutPolicy.asciiMinimumBytes,
            range.count <= EditorNativeLayoutPolicy.maximumDocumentBytes,
            snapshot.text.isPrintableASCII(in: range),
            let advance = Self.uniformAdvance(font, appearance: appearance)
        else {
            return nil
        }
        self.snapshot = snapshot
        self.range = range
        self.font = font
        self.appearance = appearance
        self.advance = advance
        renderedRange = ByteRange(range.lower, min(range.upper, range.lower + 8192))
        native = Self.project(
            snapshot: snapshot,
            range: renderedRange,
            font: font,
            appearance: appearance,
            advance: advance
        )
    }

    /// 业务作用：滚动只替换视口附近的原生片段，字节坐标与完整行宽保持原样。
    /// 参数说明:
    /// - viewport: 相对正文行起点的实际可见矩形。
    /// 返回：窗口覆盖真实可见范围，最多保留 65536 个 ASCII 字符。
    func updateViewport(_ viewport: NSRect) {
        let x = viewport.minX.isFinite ? max(0, viewport.minX) : 0
        let visibleWidth = viewport.width.isFinite ? max(1, viewport.width) : 900
        let first = column(at: x)
        let last = column(at: min(width, x + min(width, visibleWidth)))
        if first >= renderedRange.lower - range.lower,
            last <= renderedRange.upper - range.lower
        {
            return
        }
        project(around: first, visibleColumns: max(1, last - first))
    }

    /// 业务作用：像素命中使用完成排版的原生片段，不把中文、Tab 或双向文字套入等宽算法。
    /// 参数说明:
    /// - point: 相对完整逻辑行起点的命中位置。
    /// 返回：完整行内的 UTF-16 偏移，系统哨兵由原生段落适配收束。
    func character(at point: NSPoint) -> Int {
        let x = point.x.isFinite ? min(width, max(0, point.x)) : 0
        ensureColumn(column(at: x))
        let index = native.character(
            at: NSPoint(
                x: x - offsetX,
                y: point.y.isFinite ? point.y : 0
            )
        )
        return renderedRange.lower - range.lower + index
    }

    /// 业务作用：远处光标先投影附近原文，再从已经排版的字形取得插入位置。
    /// 参数说明:
    /// - local: 相对完整逻辑行的 UTF-16 偏移。
    /// 返回：同一完整行坐标中的原生光标矩形，不建立前缀字形副本。
    func caret(at local: Int) -> NSRect {
        let column = min(range.count, max(0, local))
        ensureColumn(column)
        return native.caret(at: column - (renderedRange.lower - range.lower)).offsetBy(dx: offsetX, dy: 0)
    }

    /// 业务作用：完整选择仅为实际原生窗口内的交集生成背景，内核范围不被截断。
    /// 参数说明:
    /// - selection: 原快照中的完整选择。
    /// 返回：原生可见矩形，窗口之外不生成无用片段。
    func selectionRects(_ selection: ByteRange) -> [NSRect] {
        let lower = max(selection.lower, renderedRange.lower)
        let upper = min(selection.upper, renderedRange.upper)
        guard lower < upper else {
            return []
        }
        return native.selectionRects(ByteRange(lower, upper)).map {
            $0.offsetBy(dx: offsetX, dy: 0)
        }
    }

    /// 业务作用：由 TextKit 2 完成原生字形绘制，只平移已有等宽证据的完整 ASCII 前缀距离。
    /// 参数说明:
    /// - origin: 完整逻辑行在编辑视图中的起点。
    /// - context: 当前实际绘制上下文。
    /// 返回：绘制有界原生片段，不更改正文或其它视图布局。
    func draw(at origin: NSPoint, in context: CGContext) {
        native.draw(
            at: NSPoint(
                x: origin.x + offsetX,
                y: origin.y
            ),
            in: context
        )
    }

    /// 业务作用：同一视口中的多个光标与背景共用当前段落，不逐项反复排版。
    /// 参数说明:
    /// - column: 已收束到完整行内的真实字符偏移。
    /// 返回：当前原生段落包含目标端点。
    private func ensureColumn(_ column: Int) {
        if column < renderedRange.lower - range.lower || column > renderedRange.upper - range.lower {
            project(around: column, visibleColumns: 1)
        }
    }

    /// 业务作用：投影只读取有界连续原文，分组保留滚动重用空间与真实 UTF-8 端点。
    /// 参数说明:
    /// - column: 当前真实视口或导航目标。
    /// - visibleColumns: 本次可见字符预算。
    /// 返回：重新排版最多 65536 个字符，完整逻辑行范围保持原状。
    private func project(around column: Int, visibleColumns: Int) {
        let count = min(
            range.count,
            min(
                EditorNativeLayoutPolicy.maximumWindowCharacters,
                max(8192, min(57_344, visibleColumns) + 8192)
            )
        )
        let lower = min(max(0, range.count - count), max(0, column / 4096 * 4096 - 1024))
        let next = ByteRange(range.lower + lower, range.lower + lower + count)
        guard next != renderedRange else {
            return
        }
        renderedRange = next
        native = Self.project(
            snapshot: snapshot,
            range: next,
            font: font,
            appearance: appearance,
            advance: advance
        )
    }

    /// 业务作用：浮点系统位置先收束到已验证行容量，再转为整数，哨兵和无穷值不得进入正文位置。
    /// 参数说明:
    /// - x: 已经确认有限的正文横坐标。
    /// 返回：完整行内的真实字符列。
    private func column(at x: CGFloat) -> Int {
        Int(min(CGFloat(range.count), max(0, floor(x / advance))))
    }

    /// 业务作用：有界段落仍经过真实布局管理器，关闭上下文连字与字距调整以复用等宽证据。
    /// 参数说明:
    /// - snapshot: 当前固定正文。
    /// - range: 有界原文范围。
    /// - font: 实际原生字体。
    /// - appearance: 实际视图外观。
    /// - advance: 已验证的真实原生步距。
    /// 返回：已完成 TextKit 2 排版的只读片段，不强制排版未请求正文。
    private static func project(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        font: NSFont,
        appearance: NSAppearance,
        advance: CGFloat
    ) -> LineLayout {
        LineLayout(
            snapshot: snapshot,
            range: range,
            font: font,
            width: CGFloat(range.count) * advance + 64,
            tokens: [],
            rtl: false,
            appearance: appearance,
            nativeASCII: true
        )
    }

    /// 业务作用：字体声明与全部已排版 ASCII 位置共同决定等宽资格，未排版片段不能提供步距证据。
    /// 参数说明:
    /// - font: 当前真实字体。
    /// - appearance: 当前真实视图外观。
    /// 返回：全部字符位置一致时提供真实步距，否则拒绝；证据缓存各最多三十二项。
    private static func uniformAdvance(_ font: NSFont, appearance: NSAppearance) -> CGFloat? {
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
