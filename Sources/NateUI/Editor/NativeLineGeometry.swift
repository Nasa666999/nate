import AppKit

@MainActor
struct NativeLineGeometry {
    let line: NSTextLineFragment
    let bounds: NSRect
    let lower: Int
    let upper: Int
    let sourceLength: Int

    /// 业务作用：缓存原生视觉行的真实范围与位置，重复光标查询不重新桥接整份行片段数组。
    /// 参数说明:
    /// - line: 已经完成排版的原生视觉行。
    /// - origin: 所属布局片段在逻辑段落中的起点。
    /// - sourceLength: 当前呈现段落完整 UTF-16 长度。
    /// 返回：原生范围及矩形均完整有效时建立证据，否则拒绝虚构坐标。
    init?(line: NSTextLineFragment, origin: NSPoint, sourceLength: Int) {
        let range = line.characterRange
        let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= sourceLength, range.length <= sourceLength - range.location,
            bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
            bounds.width >= 0, bounds.height >= 0
        else {
            return nil
        }
        self.line = line
        self.bounds = bounds
        lower = range.location
        upper = range.location + range.length
        self.sourceLength = sourceLength
    }

    /// 业务作用：命中继续由原生字形决定，系统哨兵只能按同一真实行的原生端点收束。
    /// 参数说明:
    /// - point: 相对逻辑段落的真实像素位置。
    /// 返回：段落内合法 UTF-16 位置，不把系统哨兵叠加到文档起点。
    func character(at point: NSPoint) -> Int {
        let local = NSPoint(
            x: point.x - bounds.minX,
            y: point.y - bounds.minY
        )
        let index = line.characterIndex(for: local)
        if index != NSNotFound, index >= 0, index <= sourceLength {
            return index
        }
        let first = line.locationForCharacter(at: lower)
        let last = line.locationForCharacter(at: upper)
        return abs(local.x - first.x) <= abs(local.x - last.x) ? lower : upper
    }

    /// 业务作用：光标位置使用已索引视觉行的原生字符边缘，保留软换行的上游亲和性。
    /// 参数说明:
    /// - local: 属于本视觉行的段落 UTF-16 位置。
    /// 返回：逻辑段落坐标中的真实原生光标矩形。
    func caret(at local: Int) -> NSRect {
        let point = line.locationForCharacter(at: local)
        return NSRect(
            x: point.x + bounds.minX,
            y: bounds.minY,
            width: 1.5,
            height: bounds.height
        )
    }

    /// 业务作用：已证明左到右 ASCII 的视觉行通过原生命中裁剪标记范围，尾随空格不展开到整段。
    /// 参数说明:
    /// - viewport: 已包含标记宽度余量的逻辑段落视口。
    /// 返回：原生行内的连续 UTF-16 范围；调用方必须先排除双向文字和非 ASCII 原文。
    func visibleASCIICharacters(in viewport: NSRect) -> NSRange {
        guard viewport.minX.isFinite, viewport.maxX.isFinite else {
            return NSRange(location: lower, length: 0)
        }
        let first = character(at: NSPoint(x: viewport.minX, y: bounds.midY))
        let last = character(at: NSPoint(x: viewport.maxX, y: bounds.midY))
        let start = max(lower, min(upper, min(first, last)) - 1)
        let end = min(upper, max(lower, max(first, last)) + 1)
        return NSRange(location: start, length: max(0, end - start))
    }
}
