import AppKit
import NateCore

@MainActor
struct PrintGeometry: Equatable {
    let width: CGFloat
    let height: CGFloat
    let header: CGFloat
    let footer: CGFloat
    let gutter: CGFloat
}

@MainActor
final class PrintedSection {
    let storage: NSTextStorage
    let layout: NSLayoutManager
    let originUTF16: Int

    /// 业务作用：每个强制分页章节独立保留系统文字排版，不能串用正文视口或另一章节的容器状态。
    /// 参数说明:
    /// - value: 本章节完整固定的属性文字。
    /// - originUTF16: 本章节在完整原文中的真实 UTF-16 起点。
    /// 返回：尚未创建页面容器的独立原生排版来源。
    init(value: NSAttributedString, originUTF16: Int) {
        storage = NSTextStorage(attributedString: value)
        layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        self.originUTF16 = originUTF16
    }
}

@MainActor
struct PrintedPage {
    let section: PrintedSection
    let container: NSTextContainer
    let glyphs: NSRange
}

@MainActor
public final class DocumentPrintView: NSView {
    let source: PrintedSource
    var pages: [PrintedPage] = []
    var geometry: PrintGeometry?
    public private(set) var failure: String?
    public var pageCount: Int {
        pages.count
    }
    public override var isFlipped: Bool {
        true
    }

    /// 业务作用：系统打印从独立固定来源分页，复制、预览与纸张变更均不触碰正文状态。
    /// 参数说明:
    /// - source: 已完整验证的独立打印来源。
    /// 返回：尚未按具体纸张计算的原生打印视图。
    public init(source: PrintedSource) {
        self.source = source
        super.init(frame: .zero)
    }

    /// 业务作用：打印视图必须绑定当前作业的固定来源，不恢复外部界面归档。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：页面绘制读取已固定的原生排版，屏幕预览和纸张输出采用同一内容。
    /// 参数说明:
    /// - dirtyRect: 当前系统请求的页面区域。
    /// 返回：仅绘制请求涉及的完整页面，不访问活动编辑器。
    public override func draw(_ dirtyRect: NSRect) {
        drawPrintedPages(in: dirtyRect)
    }

    /// 业务作用：按系统打印面板当前纸张和缩放完整重排，再一次性交付全部可打印页码。
    /// 参数说明:
    /// - range: 系统接收从 1 开始的完整页码范围的位置。
    /// 返回：始终采用自定义分页；失败提供零页并记录原因，禁止回退为整个长视图的一张截图。
    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        do {
            try prepare(printInfo: NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared)
            range.pointee = NSRange(
                location: 1,
                length: pages.count
            )
        }
        catch {
            pages.removeAll()
            geometry = nil
            failure = error.localizedDescription
            range.pointee = NSRange(
                location: 1,
                length: 0
            )
        }
        return true
    }

    /// 业务作用：系统页码只映射到已经完整准备的独立页面，不让越界请求打印邻页。
    /// 参数说明:
    /// - page: 从一开始的实际页码。
    /// 返回：对应打印视图矩形；无效页码为空矩形。
    public override func rectForPage(_ page: Int) -> NSRect {
        guard let geometry, (1...pages.count).contains(page) else {
            return .zero
        }
        return NSRect(
            x: 0,
            y: CGFloat(page - 1) * geometry.height,
            width: geometry.width,
            height: geometry.height
        )
    }

    /// 业务作用：页面区域与系统已确认的物理页边距一致，页眉页脚同样处于可打印范围内。
    /// 参数说明:
    /// - rect: 系统本次要输出的实际页矩形。
    /// 返回：纸张左下角起算的边距位置，由系统应用当前打印缩放。
    public override func locationOfPrintRect(_ rect: NSRect) -> NSPoint {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        return NSPoint(
            x: info.leftMargin,
            y: info.bottomMargin
        )
    }

    /// 业务作用：实际纸张或缩放改变后重新验证完整布局，不沿用旧宽度截断正文。
    /// 参数说明:
    /// - printInfo: 系统本次作业已确认的纸张、边距和缩放。
    /// 返回：完整页面集合原子替换；失败时既有页面不被当成新纸张的有效输出。
    public func prepare(printInfo: NSPrintInfo) throws {
        // 每个强制章节至少需要一页，容量已不可能成立时应在创建原生排版对象之前停止。
        guard source.plan.sections.count <= 10_000 else {
            throw NateError.message("完整打印作业超过一万页，未准备部分章节。")
        }
        let scale = printInfo.scalingFactor
        let size = printInfo.paperSize
        guard scale.isFinite, (0.01...100).contains(scale),
            [
                size.width, size.height, printInfo.leftMargin, printInfo.rightMargin,
                printInfo.topMargin, printInfo.bottomMargin,
            ].allSatisfy({
                $0.isFinite && $0 >= 0
            })
        else {
            throw NateError.message("打印纸张、边距或缩放不是有效有限值。")
        }
        let width = (size.width - printInfo.leftMargin - printInfo.rightMargin) / scale
        let height = (size.height - printInfo.topMargin - printInfo.bottomMargin) / scale
        let header = decorationHeight(source.settings.header)
        let footer = decorationHeight(source.settings.footer)
        let font =
            NSFont(
                descriptor: source.baseFont.fontDescriptor,
                size: source.baseFont.pointSize * source.settings.fontScale
            ) ?? source.baseFont
        let gutter: CGFloat =
            source.settings.lineNumbers
            ? (String(source.text.lineCount) as NSString).size(withAttributes: [.font: font]).width + 16 : 0
        let next = PrintGeometry(
            width: width,
            height: height,
            header: header,
            footer: footer,
            gutter: gutter
        )
        guard width - gutter >= 24, height - header - footer >= font.ascender - font.descender + font.leading,
            width <= 100_000, height <= 100_000
        else {
            throw NateError.message("当前纸张与边距无法容纳页眉、页脚及至少一行完整正文。")
        }
        if geometry == next, !pages.isEmpty {
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var prepared: [PrintedPage] = []
        guard let original = source.text.nsRange(source.plan.range) else {
            throw NateError.invalidRange
        }
        let value = try styledPrintingText()
        for range in source.plan.sections {
            try check(deadline: deadline)
            guard let sectionRange = source.text.nsRange(range), sectionRange.location >= original.location,
                sectionRange.length <= value.length - (sectionRange.location - original.location)
            else {
                throw NateError.invalidRange
            }
            let section = PrintedSection(
                value: value.attributedSubstring(
                    from: NSRange(
                        location: sectionRange.location - original.location,
                        length: sectionRange.length
                    )
                ),
                originUTF16: sectionRange.location
            )
            var consumed = 0
            repeat {
                try check(deadline: deadline)
                guard prepared.count < 10_000 else {
                    throw NateError.message("完整打印作业超过一万页，未采用部分页面。")
                }
                let container = NSTextContainer(
                    size: NSSize(
                        width: width - gutter,
                        height: height - header - footer
                    )
                )
                container.lineFragmentPadding = 0
                section.layout.addTextContainer(container)
                section.layout.ensureLayout(for: container)
                let glyphs = section.layout.glyphRange(for: container)
                guard glyphs.location != NSNotFound, glyphs.length > 0 || section.storage.length == 0,
                    NSMaxRange(glyphs) > consumed || section.storage.length == 0
                else {
                    throw NateError.message("当前页没有容纳完整正文，打印未采用截断布局。")
                }
                prepared.append(
                    PrintedPage(
                        section: section,
                        container: container,
                        glyphs: glyphs
                    )
                )
                consumed = NSMaxRange(glyphs)
            } while consumed < section.layout.numberOfGlyphs
        }
        try check(deadline: deadline)
        pages = prepared
        geometry = next
        failure = nil
        setFrameSize(
            NSSize(
                width: width,
                height: height * CGFloat(pages.count)
            )
        )
    }

    /// 业务作用：同步原生排版在每页边界响应取消，超限作业不能继续送出已准备前缀。
    /// 参数说明:
    /// - deadline: 整次重排的十秒截止时间。
    /// 返回：有效时继续，取消或超时整体失败。
    func check(deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("完整打印分页超过十秒预算。")
        }
    }
}
