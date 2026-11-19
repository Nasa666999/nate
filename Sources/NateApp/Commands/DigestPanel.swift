import AppKit
import NateStorage

enum DigestPanelResult: Sendable {
    case text(DigestValues, Int)
    case lines([LineDigest])
    case files([FileDigestOutcome])
}

enum FileDigestOutcome: Sendable {
    case success(String, FileDigestSnapshot)
    case failure(String, String)
}

@MainActor
final class DigestPanel: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let input = NSTextView(usingTextLayoutManager: true)
    let output = NSTextView(usingTextLayoutManager: true)
    let algorithms = NSPopUpButton()
    let byLine = NSButton(
        checkboxWithTitle: "每行独立计算（不包含行尾 CR / LF）",
        target: nil,
        action: nil
    )
    let status = NSTextField(wrappingLabelWithString: "输入文本或选择磁盘文件。摘要用于内容核对，不提供身份认证。")
    private let compute = NSButton(
        title: "计算文本",
        target: nil,
        action: nil
    )
    private let files = NSButton(
        title: "选择多个文件…",
        target: nil,
        action: nil
    )
    private let copy = NSButton(
        title: "复制完整结果",
        target: nil,
        action: nil
    )
    private let cancel = NSButton(
        title: "取消计算",
        target: nil,
        action: nil
    )
    private(set) var result: DigestPanelResult?
    private(set) var request = UUID()
    var onText: ((String, Bool) -> Void)?
    var onFiles: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    /// 业务作用：四类摘要共用独立输入与完整输出窗口，算法切换只读取同一固定来源的计算结果。
    /// 参数说明:
    /// - algorithm: 用户明确选择的初始算法。
    /// - lines: 是否从逐行输入入口打开。
    /// 返回：文本保持原 UTF-8 与换行；文件由显式选择入口读取磁盘原字节。
    init(algorithm: DigestAlgorithm, lines: Bool) {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 820,
                height: 620
            ),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "文本与文件摘要"
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(
            width: 680,
            height: 500
        )
        super.init(window: panel)
        panel.delegate = self
        algorithms.addItems(withTitles: DigestAlgorithm.allCases.map(\.title))
        algorithms.selectItem(at: DigestAlgorithm.allCases.firstIndex(of: algorithm) ?? 0)
        algorithms.target = self
        algorithms.action = #selector(changeAlgorithm)
        byLine.state = lines ? .on : .off
        byLine.target = self
        byLine.action = #selector(changeLineMode)
        input.delegate = self
        let inputScroll = scroll(input, editable: true)
        let outputScroll = scroll(output, editable: false)
        input.setAccessibilityLabel("摘要直接文本输入")
        output.setAccessibilityLabel("完整摘要结果")
        let explanation = NSTextField(
            wrappingLabelWithString:
                "文本：UTF-8 原字节，保留 BOM、NUL 和原换行；逐行模式排除各行行尾，保留末尾空行。文件：磁盘全部原字节，不使用未保存缓冲区。文本最多 64 MiB、逐行最多十万行。"
        )
        explanation.textColor = .secondaryLabelColor
        for (button, action) in [
            (compute, #selector(computeText)),
            (files, #selector(chooseFiles)),
            (copy, #selector(copyResult)),
            (cancel, #selector(cancelWork)),
        ] {
            button.target = self
            button.action = action
        }
        let choices = NSStackView(views: [algorithms, byLine])
        choices.spacing = 12
        let actions = NSStackView(views: [compute, files, copy, cancel])
        actions.spacing = 8
        let inputLabel = NSTextField(labelWithString: "直接文本输入")
        let outputLabel = NSTextField(labelWithString: "完整结果（支持横向与纵向滚动）")
        let stack = NSStackView(views: [
            choices, explanation, inputLabel, inputScroll, actions, outputLabel, outputScroll, status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSBox()
        root.boxType = .custom
        root.title = ""
        root.borderWidth = 0
        root.contentViewMargins = .zero
        root.fillColor = .windowBackgroundColor
        panel.contentView = root
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            inputScroll.heightAnchor.constraint(equalTo: outputScroll.heightAnchor, multiplier: 0.65),
        ]
        for view in [explanation, inputScroll, outputScroll, status] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setBusy(false)
        panel.center()
    }

    /// 业务作用：摘要窗口不从界面归档恢复旧输入与旧文件结果。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：拒绝归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：独立纯文本视图不解释粘贴内容为富文本或自动改写引号与标点。
    /// 参数说明:
    /// - view: 输入或只读结果视图。
    /// - editable: 是否允许直接编辑。
    /// 返回：保留全部文本并提供横纵滚动的原生区域。
    private func scroll(_ view: NSTextView, editable: Bool) -> NSScrollView {
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = view
        return scroll
    }

    /// 业务作用：新请求先撤去旧输出资格，等待期间不能复制上一输入的摘要。
    /// 参数说明: 无。
    /// 返回：新的发布身份，原结果已清空。
    func begin() -> UUID {
        request = UUID()
        result = nil
        output.string = ""
        setBusy(true)
        return request
    }

    /// 业务作用：真实后台工作结束前保持重复计算关闭，取消不冒充底层读取已经返回。
    /// 参数说明:
    /// - busy: 是否仍有实际计算占用。
    /// 返回：更新入口与复制资格，不修改结果。
    func setBusy(_ busy: Bool) {
        compute.isEnabled = !busy
        files.isEnabled = !busy
        cancel.isEnabled = busy
        copy.isEnabled = !busy && result != nil
    }

    /// 业务作用：只有原请求仍有效时接收完整结果，迟到结果不能覆盖新输入。
    /// 参数说明:
    /// - value: 完整固定结果。
    /// - request: 发起时的原发布身份。
    /// 返回：匹配时显示全部结果，不匹配时保持当前输入状态。
    func publish(_ value: DigestPanelResult, request: UUID) {
        guard self.request == request else {
            return
        }
        result = value
        render()
    }

    /// 业务作用：输入改变立即撤销旧任务与旧复制内容，往返输入也不恢复旧请求权威。
    /// 参数说明:
    /// - notification: 原生文本变化通知。
    /// 返回：保持当前输入，清除来源已经过期的结果。
    func textDidChange(_ notification: Notification) {
        invalidate()
    }

    /// 业务作用：关闭窗口先撤销发布资格并请求取消，再交还控制器持有权。
    /// 参数说明:
    /// - notification: 原生窗口关闭通知。
    /// 返回：关闭后不再接收后台结果。
    func windowWillClose(_ notification: Notification) {
        invalidate()
        onClose?()
    }

    /// 业务作用：算法改变只重新展示已经完成的全部摘要，不重新读取可能变化的文件。
    /// 参数说明: 无。
    /// 返回：保留原来源和时间证据的完整输出。
    @objc private func changeAlgorithm() {
        render()
    }

    /// 业务作用：逐行规则改变后原结果不再代表当前输入解释。
    /// 参数说明: 无。
    /// 返回：清除旧输出并取消原任务。
    @objc private func changeLineMode() {
        invalidate()
    }

    /// 业务作用：固定当前输入后请求完整文本或逐行摘要。
    /// 参数说明: 无。
    /// 返回：由业务控制器执行有界后台计算。
    @objc private func computeText() {
        onText?(input.string, byLine.state == .on)
    }

    /// 业务作用：文件来源必须经用户明确选择，不从正文路径或剪贴板自动读取。
    /// 参数说明: 无。
    /// 返回：交由业务控制器打开多文件选择器。
    @objc private func chooseFiles() {
        onFiles?()
    }

    /// 业务作用：用户明确复制完整当前结果，不自动覆盖计算期间的系统剪贴板。
    /// 参数说明: 无。
    /// 返回：仅在完整结果可复制时发布全部文本。
    @objc private func copyResult() {
        guard copy.isEnabled, result != nil else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.string, forType: .string)
        status.stringValue = "已复制完整结果。"
    }

    /// 业务作用：显式取消撤去当前结果发布权，但保留真实后台占用直至返回。
    /// 参数说明: 无。
    /// 返回：不展示部分摘要，不改变用户输入。
    @objc private func cancelWork() {
        invalidate()
    }

    /// 业务作用：统一撤销旧输入对应的结果和回调发布资格。
    /// 参数说明: 无。
    /// 返回：取消原工作，复制入口关闭。
    private func invalidate() {
        request = UUID()
        result = nil
        output.string = ""
        copy.isEnabled = false
        onCancel?()
        status.stringValue = "输入或计算已改变，请重新计算。"
    }

    /// 业务作用：完整展示摘要来源，不把结果前缀或文件失败项表示为完整成功。
    /// 参数说明: 无。
    /// 返回：单文本输出摘要，逐行输出每行摘要，文件输出实际路径、字节数及各项状态。
    private func render() {
        let index = algorithms.indexOfSelectedItem
        guard DigestAlgorithm.allCases.indices.contains(index), let result else {
            return
        }
        let algorithm = DigestAlgorithm.allCases[index]
        switch result {
        case .text(let values, let bytes):
            output.string = values.value(for: algorithm)
            status.stringValue = "固定文本 · UTF-8 原换行 · \(bytes) 字节"
        case .lines(let lines):
            output.string = lines.map {
                $0.values.value(for: algorithm)
            }.joined(separator: "\n")
            status.stringValue = "固定文本 · \(lines.count) 行 · 每行排除实际行尾，末尾空行保留"
        case .files(let files):
            status.stringValue = "\(files.count) 项文件结果；每个摘要仅代表本次读取完成时的固定原字节。"
            output.string = files.map {
                switch $0 {
                case .success(let chosenPath, let file):
                    return
                        "\(algorithm.title)  \(file.values.value(for: algorithm))\n实际路径：\(String(reflecting: file.baseline.resolvedPath))\n选择路径：\(String(reflecting: chosenPath))\n完整原字节：\(file.byteCount)\n"
                case .failure(let path, let message):
                    return "未取得摘要：\(String(reflecting: path))\n原因：\(message)\n"
                }
            }.joined(separator: "\n")
        }
        output.scrollToBeginningOfDocument(nil)
    }
}
