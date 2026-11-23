import AppKit

@MainActor
final class LineForegroundVariant {
    let color: NSColor
    let content: EditorContentManager
    let manager: NSTextLayoutManager
    private var fragments: [NSTextLayoutFragment] = []

    /// 业务作用：选择文字只替换有限呈现副本的前景，原排版、正文与坐标继续由原行持有。
    /// 参数说明:
    /// - source: 当前完整有界原生段落。
    /// - color: 来源主题明确选择的文字颜色。
    /// - width: 原段落真实容器宽度。
    /// - appearance: 原段落来源外观。
    /// 返回：保留原字体与段落属性的只读颜色副本，不写入原呈现或正文。
    init(source: EditorContentManager, color: NSColor, width: CGFloat, appearance: NSAppearance) {
        self.color = color
        let value = NSMutableAttributedString(attributedString: source.rendered)
        value.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: value.length))
        content = EditorContentManager(
            snapshot: source.snapshot,
            projection: source.projection,
            rendered: value
        )
        manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        appearance.performAsCurrentDrawingAppearance {
            manager.ensureLayout(for: content.documentRange)
            manager.enumerateTextLayoutFragments(
                from: content.documentRange.location,
                options: [.ensuresLayout]
            ) {
                fragment in
                self.fragments.append(fragment)
                return false
            }
        }
    }

    /// 业务作用：选择颜色只在调用方已裁剪的实际选择区域绘制，完整行的其它字形保持原样。
    /// 参数说明:
    /// - origin: 原行的真实绘制原点。
    /// - context: 已建立选择裁剪的绘图上下文。
    /// 返回：颜色副本的同源字形绘制，不取得排版或选择修改权。
    func draw(at origin: NSPoint, in context: CGContext) {
        for fragment in fragments {
            fragment.draw(
                at: NSPoint(
                    x: origin.x + fragment.layoutFragmentFrame.minX,
                    y: origin.y + fragment.layoutFragmentFrame.minY
                ),
                in: context
            )
        }
    }
}
