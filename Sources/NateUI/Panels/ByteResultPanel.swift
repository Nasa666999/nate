import AppKit
import Foundation

@MainActor
public final class ByteResultPanel: NSWindowController, NSWindowDelegate {
    public let data: Data
    public var onExport: (() -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var pageOffset = 0
    public static let pageSize = 4096
    private let content = NSTextView(usingTextLayoutManager: true)
    private let offset = NSTextField(string: "0")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previous = NSButton(
        title: "上一页",
        target: nil,
        action: nil
    )
    private let next = NSButton(
        title: "下一页",
        target: nil,
        action: nil
    )
    private let export = NSButton(
        title: "导出全部原字节…",
        target: nil,
        action: nil
    )

    /// 业务作用：独立保留非文本解码结果，分页展示全部可寻址字节，不把十六进制显示写回正文。
    /// 参数说明:
    /// - data: 完整且已经通过容量限制的不可变解码结果。
    /// - name: 用户明确选择的来源工具名称。
    /// 返回：每页四 KiB、可跳转任意偏移并导出全部原字节的只读窗口。
    public init(data: Data, name: String) {
        self.data = Data(data)
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 860,
                height: 580
            ),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "字节结果 · " + name
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(
            width: 700,
            height: 360
        )
        super.init(window: panel)
        panel.delegate = self
        let explanation = NSTextField(
            wrappingLabelWithString:
                "结果不是合法 UTF-8 文本。此窗口保留全部原字节；左侧为十六进制偏移，中间为原字节，右侧仅显示可打印 ASCII。原正文和文件保持原状。"
        )
        explanation.textColor = .secondaryLabelColor
        content.isEditable = false
        content.isSelectable = true
        content.isRichText = false
        content.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.isHorizontallyResizable = true
        content.isVerticallyResizable = true
        content.textContainer?.widthTracksTextView = false
        content.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        content.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.documentView = content
        previous.target = self
        previous.action = #selector(previousPage)
        next.target = self
        next.action = #selector(nextPage)
        export.target = self
        export.action = #selector(exportBytes)
        offset.placeholderString = "十进制或 0x 十六进制偏移"
        offset.setAccessibilityLabel("完整结果中的字节偏移")
        let go = NSButton(
            title: "跳转",
            target: self,
            action: #selector(goToOffset)
        )
        offset.target = self
        offset.action = #selector(goToOffset)
        let actions = NSStackView(views: [previous, next, offset, go, export])
        actions.spacing = 8
        let stack = NSStackView(views: [explanation, scroll, status, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSBox()
        root.boxType = .custom
        root.borderWidth = 0
        root.title = ""
        root.contentViewMargins = .zero
        root.fillColor = .windowBackgroundColor
        panel.contentView = root
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            offset.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ]
        for view in [explanation, scroll, status, actions] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        show(offset: 0)
        panel.center()
    }

    /// 业务作用：字节结果只来自当前完整解码，不恢复归档中的旧输出。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：不支持界面归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：按真实字节偏移读取单页，任意大结果的导航都不构建全篇十六进制字符串。
    /// 参数说明:
    /// - offset: 零起算原字节偏移，末尾与越界请求收束到最后实际页。
    /// 返回：显示目标所在的四 KiB 页，保留全部未展示原字节。
    public func show(offset requested: Int) {
        let last = max(0, data.count - 1)
        pageOffset = min(max(0, requested), last) / Self.pageSize * Self.pageSize
        let end = min(data.count, pageOffset + Self.pageSize)
        var rows: [String] = []
        for start in stride(from: pageOffset, to: end, by: 16) {
            let bytes = data[start..<min(start + 16, end)]
            let hex = bytes.map {
                String(format: "%02X", $0)
            }.joined(separator: " ")
            let ascii =
                String(
                    bytes: bytes.map {
                        (32...126).contains($0) ? $0 : 46
                    },
                    encoding: .ascii
                ) ?? ""
            rows.append(
                String(format: "%08X", start) + "  " + hex.padding(toLength: 47, withPad: " ", startingAt: 0)
                    + "  " + ascii
            )
        }
        content.string = rows.joined(separator: "\n")
        content.scrollToBeginningOfDocument(nil)
        offset.stringValue = String(pageOffset)
        status.stringValue = "完整结果 \(data.count) 字节 · 当前 [\(pageOffset), \(end)) · 导出始终包含全部原字节。"
        previous.isEnabled = pageOffset > 0
        next.isEnabled = end < data.count
    }

    /// 业务作用：导出期间关闭重复保存入口，窗口仍允许读取独立结果。
    /// 参数说明:
    /// - busy: 是否仍有本窗口发起的完整保存。
    /// 返回：只改变导出按钮，不改变保留字节与当前页。
    public func setExporting(_ busy: Bool) {
        export.isEnabled = !busy
    }

    /// 业务作用：上一页导航始终按原结果偏移计算。
    /// 参数说明: 无。
    /// 返回：显示上一实际页，不读写源文档。
    @objc private func previousPage() {
        show(offset: pageOffset - Self.pageSize)
    }

    /// 业务作用：下一页只访问仍存在的完整结果字节。
    /// 参数说明: 无。
    /// 返回：显示下一页或保持最后一页。
    @objc private func nextPage() {
        show(offset: pageOffset + Self.pageSize)
    }

    /// 业务作用：用户明确输入的十进制或十六进制偏移经过完整解析后导航。
    /// 参数说明: 无。
    /// 返回：非法或超出 Int 的输入保留当前页并显示原因。
    @objc private func goToOffset() {
        let value = offset.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.hasPrefix("0x") || value.hasPrefix("0X")
        guard let number = Int(hex ? String(value.dropFirst(2)) : value, radix: hex ? 16 : 10), number >= 0
        else {
            status.stringValue = "偏移必须为合法的非负十进制或 0x 十六进制整数。"
            return
        }
        show(offset: number)
    }

    /// 业务作用：只有明确导出按钮才请求文件写入，显示和跳页本身没有磁盘副作用。
    /// 参数说明: 无。
    /// 返回：通知应用保存全部固定字节。
    @objc private func exportBytes() {
        if export.isEnabled {
            onExport?()
        }
    }

    /// 业务作用：窗口关闭释放本次结果引用，不把旧关闭事件用于后来结果。
    /// 参数说明:
    /// - notification: 原生关闭事件。
    /// 返回：通知持有者释放当前窗口。
    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
