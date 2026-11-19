import AppKit
import NateCore

extension DocumentPrintView {
    /// 业务作用：正文与装饰在各自保留区域内绘制，语法背景不能遮住页眉页脚或相邻页。
    /// 参数说明:
    /// - rect: 系统当前请求的打印视图区域。
    /// 返回：独立排版产生文字、行号与三栏装饰；无完整分页时不绘制任何前缀。
    func drawPrintedPages(in rect: NSRect) {
        guard let geometry, !pages.isEmpty, rect.minY.isFinite, rect.maxY.isFinite else {
            return
        }
        let current = NSPrintOperation.current?.currentPage ?? 0
        let printingPage =
            NSGraphicsContext.current?.isDrawingToScreen != true && current > 0 && current <= pages.count
        // 打印上下文的脏区可能包含物理页边距，不能因此把下一页内容写入当前 PDF 页的隐藏区域。
        let first = printingPage ? current - 1 : max(0, Int(max(0, rect.minY) / geometry.height))
        let last =
            printingPage
            ? current - 1 : min(pages.count - 1, max(0, Int(ceil(max(0, rect.maxY) / geometry.height)) - 1))
        guard first <= last else {
            return
        }
        for index in first...last {
            let page = pages[index], origin = CGFloat(index) * geometry.height
            let full = NSRect(
                x: 0,
                y: origin,
                width: geometry.width,
                height: geometry.height
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: full).addClip()
            pageBackground.setFill()
            full.fill()
            let body = NSPoint(
                x: geometry.gutter,
                y: origin + geometry.header
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                rect: NSRect(
                    x: body.x,
                    y: body.y,
                    width: geometry.width - geometry.gutter,
                    height: geometry.height - geometry.header - geometry.footer
                )
            ).addClip()
            page.section.layout.drawBackground(forGlyphRange: page.glyphs, at: body)
            page.section.layout.drawGlyphs(forGlyphRange: page.glyphs, at: body)
            NSGraphicsContext.restoreGraphicsState()
            if source.settings.lineNumbers {
                drawLineNumbers(page, at: body, width: geometry.gutter)
            }
            drawDecoration(source.settings.header, page: index + 1, y: origin, width: geometry.width)
            drawDecoration(
                source.settings.footer,
                page: index + 1,
                y: origin + geometry.height - geometry.footer + 6,
                width: geometry.width
            )
            // 彩色字体可内嵌位图，最终纸面合成覆盖全部字形而不把可选择文字栅格化。
            if source.settings.color == .blackOnWhite {
                if let context = NSGraphicsContext.current?.cgContext {
                    context.setBlendMode(.saturation)
                    context.setFillColor(
                        CGColor(
                            gray: 0,
                            alpha: 1
                        )
                    )
                    context.fill(full)
                }
            }
            else if source.settings.color == .inverted {
                if let context = NSGraphicsContext.current?.cgContext {
                    context.setBlendMode(.difference)
                    context.setFillColor(
                        CGColor(
                            gray: 1,
                            alpha: 1
                        )
                    )
                    context.fill(full)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 业务作用：页眉页脚占用独立的原生字体行高，不依赖屏幕文字尺寸猜测可用正文高度。
    /// 参数说明:
    /// - value: 固定三栏装饰配置。
    /// 返回：三个区域全空时不占空间，其余保留一整行和六点间隔。
    func decorationHeight(_ value: PrintDecoration) -> CGFloat {
        guard !value.left.isEmpty || !value.middle.isEmpty || !value.right.isEmpty else {
            return 0
        }
        let font = decorationFont(value)
        return ceil(font.ascender - font.descender + font.leading) + 6
    }

    /// 业务作用：装饰字体独立于打印字号缩放，空字体名只沿用正文家族。
    /// 参数说明:
    /// - value: 已完整验证的实际字体配置。
    /// 返回：按明确字号和粗斜体组合得到的系统字体。
    func decorationFont(_ value: PrintDecoration) -> NSFont {
        var font =
            NSFont(
                name: value.fontName.isEmpty ? source.baseFont.fontName : value.fontName,
                size: value.fontSize
            ) ?? NSFont.monospacedSystemFont(ofSize: value.fontSize, weight: .regular)
        if value.bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if value.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// 业务作用：页码采用本次实际分页，元数据始终使用作业开始时的固定原文与时间。
    /// 参数说明:
    /// - value: 固定三栏模板及字体。
    /// - page: 当前一开始的实际页码。
    /// - y: 当前装饰区域的打印视图起点。
    /// - width: 本页当前打印宽度。
    /// 返回：分别在左、中、右三个受限区域绘制，长路径不覆盖其它区或正文。
    private func drawDecoration(_ value: PrintDecoration, page: Int, y: CGFloat, width: CGFloat) {
        guard decorationHeight(value) > 0 else {
            return
        }
        let font = decorationFont(value)
        for (index, template) in [value.left, value.middle, value.right].enumerated() {
            guard
                let text = try? PrintTemplate(template).render(
                    values: source.values,
                    page: page,
                    totalPages: pages.count
                )
            else {
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = index == 0 ? .left : index == 1 ? .center : .right
            paragraph.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: pageForeground,
                .paragraphStyle: paragraph,
            ]
            let area = NSRect(
                x: CGFloat(index) * width / 3 + 2,
                y: y,
                width: max(0, width / 3 - 4),
                height: decorationHeight(value) - 6
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            (text as NSString).draw(in: area, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 业务作用：行号来自原正文的实际逻辑行，软换行续行不会被误编号为新源行。
    /// 参数说明:
    /// - page: 当前完整页面及原生字形范围。
    /// - origin: 正文字形绘制原点。
    /// - width: 为行号独立保留的横向空间。
    /// 返回：仅在真实行首或选区第一行绘制原行号，不改变正文排版宽度与字节。
    private func drawLineNumbers(_ page: PrintedPage, at origin: NSPoint, width: CGFloat) {
        let manager = page.section.layout
        manager.enumerateLineFragments(forGlyphRange: page.glyphs) {
            [self] _, used, _, glyphs, _ in
            let local = manager.characterIndexForGlyph(at: glyphs.location)
            guard let byte = source.text.byteOffset(utf16: page.section.originUTF16 + local) else {
                return
            }
            let row = source.text.lineNumber(at: byte)
            guard byte == source.text.lineStart(row) || byte == source.plan.range.lower else {
                return
            }
            let font =
                page.section.storage.attribute(
                    .font,
                    at: min(local, max(0, page.section.storage.length - 1)),
                    effectiveRange: nil
                ) as? NSFont ?? source.baseFont
            let number = String(row + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: pageForeground,
            ]
            let size = number.size(withAttributes: attributes)
            number.draw(
                at: NSPoint(
                    x: width - size.width - 8,
                    y: origin.y + used.minY
                ),
                withAttributes: attributes
            )
        }
    }

    /// 业务作用：打印背景由明确颜色方案决定，黑白与去背景模式始终采用白纸。
    /// 参数说明: 无。
    /// 返回：文档与反色方案先铺固定原背景，黑白与去背景方案铺白色；反色在全部字形完成后统一合成。
    var pageBackground: NSColor {
        switch source.settings.color {
        case .document, .inverted: return source.background
        case .blackOnWhite, .noBackground: return .white
        }
    }

    /// 业务作用：页码与行号在文档反色背景上保持与正文一致的可读前景。
    /// 参数说明: 无。
    /// 返回：当前固定打印方案采用的装饰前景色。
    var pageForeground: NSColor {
        if source.settings.color == .document || source.settings.color == .inverted {
            let luminance =
                pageBackground.redComponent * 0.2126 + pageBackground.greenComponent * 0.7152 + pageBackground
                .blueComponent * 0.0722
            return luminance < 0.5 ? .white : .black
        }
        return .black
    }

}
