import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：独立输出固定来源编辑器的实际整体底色，不借用打印面板的系统外观。
    /// 参数说明: 无。
    /// 返回：当前主题或来源系统外观中的固定底色。
    public var presentationBackground: NSColor {
        themeColor(.background, fallback: .textBackgroundColor)
    }

    /// 业务作用：主题发布只重建显示与几何权限，原正文、保存点、组合内容和完整选择保持原样。
    /// 参数说明: 无。
    /// 返回：旧字体布局与依赖它的剪贴板动作失权，当前主题在真实视图中生效。
    func editorThemeDidChange() {
        // 旧矩形像素不能沿新字体解释；先撤销旧动作并发布新的稳定样式身份，再建立新布局。
        clipboard.cancel()
        layouts.removeAll()
        projection.measured.removeAll()
        updateRectangleStyleIdentity()
        refresh(reveal: false)
        inputContext?.invalidateCharacterCoordinates()
    }

    /// 业务作用：编辑器整体角色只读取本视图固定主题，默认色仍在本视图外观中解析。
    /// 参数说明:
    /// - role: 当前绘制的整体颜色角色。
    /// - fallback: 角色没有明确设置时的既有系统或资源颜色。
    /// 返回：本视图来源外观中的固定 sRGB 颜色。
    func themeColor(_ role: EditorThemeColorRole, fallback: NSColor) -> NSColor {
        EditorThemePresentation.color(
            role,
            fallback: fallback,
            theme: editorTheme?.definition,
            appearance: effectiveAppearance,
            language: language?.id
        )
    }

    /// 业务作用：主题选择前景沿原字节范围与真实字形裁剪重绘，字体、选择和原呈现缓存不变。
    /// 参数说明:
    /// - layout: 当前来源的完整有界行布局。
    /// - y: 当前行实际纵坐标。
    /// - context: 当前来源绘图上下文。
    /// 返回：至多 4096 个实际选择矩形采用明确前景，未选择内容保持原样。
    func drawThemeSelectionForeground(in layout: LineLayout, y: CGFloat, context: CGContext) {
        guard composition == nil, editorTheme?.definition.colors["selectionForeground"] != nil else {
            return
        }
        var rects: [CGRect] = []
        for selection in viewSelections where !selection.range.isEmpty {
            let lower = max(selection.range.lower, layout.renderedRange.lower)
            let upper = min(selection.range.upper, layout.renderedRange.upper)
            if lower >= upper {
                continue
            }
            for rect in layout.selectionRects(ByteRange(lower, upper)) {
                guard rects.count < 4096 else {
                    markDisplayStatus = "选择文字配色暂停：当前行的选择字形范围超过 4096 个，原正文与选择保持。"
                    return
                }
                rects.append(rect.offsetBy(dx: gutterWidth, dy: y))
            }
        }
        guard !rects.isEmpty else {
            return
        }
        context.saveGState()
        context.addRects(rects)
        context.clip()
        layout.drawForeground(
            at: NSPoint(x: gutterWidth, y: y),
            color: themeColor(.selectionForeground, fallback: .selectedTextColor),
            in: context
        )
        context.restoreGState()
    }
}
