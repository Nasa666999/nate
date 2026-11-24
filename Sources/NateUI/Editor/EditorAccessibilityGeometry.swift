import AppKit
import NateCore

extension EditorView {
    /// 业务作用：系统以 UTF-16 任何有效索引查询所在完整字形，辅助光标不切开组合与代理对。
    /// 参数说明:
    /// - index: 已提交正文中的系统 UTF-16 索引。
    /// 返回：完整字形范围，结尾返回零长范围，非法索引或排查超量时返回无效范围。
    public override func accessibilityRange(for index: Int) -> NSRange {
        let text = document.text
        guard (0...text.utf16Count).contains(index) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        if index == text.utf16Count {
            return NSRange(location: index, length: 0)
        }
        // 系统可以查询低代理项，但字节索引和字形遍历仍只接受完整的 Unicode 标量。
        guard
            let byte = text.byteOffset(utf16: index)
                ?? (index > 0 ? text.byteOffset(utf16: index - 1) : nil),
            var navigation = try? GraphemeNavigation(text: text),
            let range = try? navigation.range(at: byte, forward: true)
        else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityRange(forBytes: range)
    }

    /// 业务作用：用当前视图的原生字形证据解析 VoiceOver 的屏幕命中。
    /// 参数说明:
    /// - point: AppKit 屏幕坐标。
    /// 返回：真实命中的完整字形，边栏、空白、遮蔽或没有正文证据时返回无效范围。
    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        let missing = NSRange(location: NSNotFound, length: 0)
        guard !hasMarkedText(), let window, point.x.isFinite, point.y.isFinite else {
            return missing
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let viewport = visibleRect
        guard viewport.contains(local), local.x >= viewport.minX + gutterWidth, local.y >= 8 else {
            return missing
        }
        let text = document.text
        let line = projection.line(at: local.y - 8)
        let layout = layoutLine(line)
        let originY = projection.y(of: line) + 8
        let position = NSPoint(x: local.x - gutterWidth, y: local.y - originY)
        guard layout.unavailableReason == nil, (0..<layout.height).contains(position.y),
            layout.characterCount > 0
        else {
            return missing
        }
        let hit = min(layout.characterCount, max(0, layout.character(at: position)))
        guard layout.unavailableReason == nil else {
            return missing
        }
        // TextKit 可返回字形两侧的插入点；只有当前选区片段覆盖指针才作为真实字符命中。
        let indices = [hit, max(0, hit - 1)]
        for index in indices {
            let range = accessibilityRange(for: layout.originUTF16 + index)
            guard let bytes = text.byteRange(range), bytes.lower >= layout.range.lower,
                bytes.upper <= layout.range.upper, !bytes.isEmpty
            else {
                continue
            }
            if layout.selectionRects(bytes).contains(where: { $0.contains(position) }) {
                return range
            }
        }
        return missing
    }

    /// 业务作用：辅助客户端在正确窗口与屏幕上定位提交正文的实际可见字形。
    /// 参数说明:
    /// - range: 当前文档的严格 UTF-16 查询范围。
    /// 返回：可见部分的真实屏幕外框；无可见字形、正文候选或资源不足时返回空框。
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let text = document.text
        guard let window, let visible = visibleLogicalLineRange(), !visible.isEmpty,
            let bytes = text.byteRange(range), bytes.count <= Self.maximumSystemTextBytes
        else {
            return .zero
        }
        let first = text.lineNumber(at: bytes.lower)
        let last = text.lineNumber(at: bytes.isEmpty ? bytes.lower : bytes.upper - 1)
        let lowerLine = max(visible.lowerBound, first)
        let upper = min(visible.upperBound - 1, last)
        var line = hiddenLines.visibleAfterOrAt(lowerLine, count: text.lineCount)
        var remainingLines = 512
        var screenBounds = NSRect.null
        let viewport = visibleRect
        let body = NSRect(
            x: viewport.minX + gutterWidth,
            y: viewport.minY,
            width: max(0, viewport.width - gutterWidth),
            height: viewport.height
        )
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while line >= lowerLine && line <= upper {
            // 避免系统一次查询迫使主线程排版长文档。耗尽容量时不返回误导性的部分边框。
            guard remainingLines > 0, ContinuousClock.now < deadline else {
                return .zero
            }
            remainingLines -= 1
            let layout = layoutLine(line)
            guard layout.unavailableReason == nil, ContinuousClock.now < deadline else {
                return .zero
            }
            let offsetY = projection.y(of: line) + 8
            let paragraph = layout.range
            let lower = max(paragraph.lower, bytes.lower)
            let limit = min(paragraph.upper, bytes.upper)
            if lower < limit {
                for rect in layout.selectionRects(ByteRange(lower, limit)) {
                    let shown = rect.offsetBy(dx: gutterWidth, dy: offsetY).intersection(body)
                    if !shown.isEmpty {
                        screenBounds = screenBounds.union(shown)
                    }
                }
            }
            // 换行符没有普通字形，使用所在逻辑行的真实结束位置。零长请求说明插入位置。
            if bytes.isEmpty || bytes.upper > paragraph.upper,
                let units = text.utf16Offset(
                    byte: min(paragraph.upper, bytes.isEmpty ? bytes.lower : paragraph.upper)
                )
            {
                let local = layout.caret(at: units - layout.originUTF16, downstream: true)
                guard layout.unavailableReason == nil else {
                    return .zero
                }
                let shown = local.offsetBy(dx: gutterWidth, dy: offsetY).intersection(body)
                if !shown.isEmpty {
                    screenBounds = screenBounds.union(shown)
                }
            }
            let next = hiddenLines.visibleAfterOrAt(line + 1, count: text.lineCount)
            guard next > line else {
                break
            }
            line = next
        }
        guard !screenBounds.isNull, ContinuousClock.now < deadline else {
            return .zero
        }
        return window.convertToScreen(convert(screenBounds, to: nil))
    }
}
