import AppKit
import NateCore

@MainActor
protocol LongLineProjection: AnyObject {
    var content: EditorContentManager { get }
    var manager: NSTextLayoutManager { get }
    var renderedRange: ByteRange { get }
    var unavailableReason: String? { get }
    var characterCount: Int { get }
    var width: CGFloat { get }
    var height: CGFloat { get }

    /// 业务作用：按当前可见区域准备实际原生窗口。
    /// 参数说明:
    /// - viewport: 完整逻辑行坐标中的正文视口。
    /// 返回：对应的有界片段与当前来源的几何证据。
    func updateViewport(_ viewport: NSRect)

    /// 业务作用：将真实原生字形命中映射到完整逻辑行的字符位置。
    /// 参数说明:
    /// - point: 完整逻辑行坐标中的实际命中点。
    /// 返回：原行 UTF-16 位置；无有效几何时暂停映射。
    func character(at point: NSPoint) -> Int

    /// 业务作用：以实际字形边缘定位编辑光标和操作面板。
    /// 参数说明:
    /// - local: 完整逻辑行内的 UTF-16 位置。
    /// - downstream: 是否使用软换行后相邻视觉行的边缘。
    /// 返回：完整行坐标中的原生光标矩形。
    func caret(at local: Int, downstream: Bool) -> NSRect

    /// 业务作用：使用当前原生窗口确定显示范围，全文选择仍由内核保留。
    /// 参数说明:
    /// - selection: 完整原文的实际字节范围。
    /// 返回：该范围在活动窗口中的可见原生片段。
    func selectionRects(_ selection: ByteRange) -> [NSRect]

    /// 业务作用：为屏幕标记和辅助读取提供真实可见原文。
    /// 参数说明:
    /// - viewport: 完整逻辑行坐标中的请求范围。
    /// 返回：可见原生片段的合法原始字节范围。
    func visibleByteRanges(in viewport: NSRect) -> [ByteRange]

    /// 业务作用：在完整逻辑行坐标中呈现当前有界原生内容。
    /// 参数说明:
    /// - origin: 当前逻辑行在编辑器中的实际坐标。
    /// - context: 真实绘制上下文。
    /// 返回：只呈现实际可见字形，正文由内核继续管理。
    func draw(at origin: NSPoint, in context: CGContext)

    /// 业务作用：让可见选择前景与同一原生字形对齐。
    /// 参数说明:
    /// - origin: 当前逻辑行实际绘制起点。
    /// - color: 主题的明确选择前景。
    /// - context: 已裁剪为实际选择的绘制上下文。
    /// 返回：对应原始选择的屏幕前景，无正文副作用。
    func drawForeground(at origin: NSPoint, color: NSColor, in context: CGContext)
}
