import AppKit
import NateCore

@MainActor
final class RunCommandForm: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var onEdit: (() -> Void)?
    var onError: ((String) -> Void)?
    private let name = NSTextField()
    private let program = NSTextView(usingTextLayoutManager: true)
    private let arguments = NSTextView(usingTextLayoutManager: true)
    private let directory = NSTextView(usingTextLayoutManager: true)
    private let shortcut = MacroShortcutCapture()
    private let clear = NSButton(title: "清空绑定", target: nil, action: nil)

    /// 业务作用：程序、目录与参数使用完整可滚动原文编辑，不把路径空格或换行当作 shell 分隔符。
    /// 参数说明: 无。
    /// 返回：尚未绑定配置身份的独立完整表单。
    init() {
        super.init(frame: .zero)
        name.placeholderString = "配置名称"
        name.delegate = self
        name.setAccessibilityLabel("运行配置名称")
        let programScroll = area(program, label: "程序绝对路径模板")
        let argumentScroll = area(arguments, label: "JSON 参数数组")
        let directoryScroll = area(directory, label: "工作目录模板")
        let explanation = NSTextField(
            wrappingLabelWithString:
                "参数填写 JSON 字符串数组，每项独立传递。变量：${file}、${directory}、${name}、${stem}、${extension}、${selection}、${word}、${lineText}、${line}、${column}。$$ 表示字面美元符；工作目录留空使用当前文件目录或进程当前目录。"
        )
        explanation.textColor = .secondaryLabelColor
        let shortcutRow = NSStackView(views: [
            NSTextField(labelWithString: "快捷键"), shortcut, NSView(),
        ])
        shortcutRow.spacing = 8
        clear.target = self
        clear.action = #selector(clearShortcut)
        shortcutRow.addArrangedSubview(clear)
        let stack = NSStackView(views: [
            name, NSTextField(labelWithString: "程序绝对路径模板"), programScroll,
            NSTextField(labelWithString: "JSON 参数数组"), argumentScroll,
            NSTextField(labelWithString: "工作目录模板"), directoryScroll, shortcutRow, explanation,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            programScroll.heightAnchor.constraint(equalToConstant: 44),
            argumentScroll.heightAnchor.constraint(equalToConstant: 100),
            directoryScroll.heightAnchor.constraint(equalToConstant: 44),
            shortcut.widthAnchor.constraint(equalToConstant: 260),
            shortcut.heightAnchor.constraint(equalToConstant: 28),
        ]
        for view in [name, programScroll, argumentScroll, directoryScroll, shortcutRow, explanation] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        shortcut.onError = {
            [weak self] in self?.onError?($0)
        }
        load(nil)
    }

    /// 业务作用：表单只由当前管理界面建立，不恢复外部界面归档的执行状态。
    /// 参数说明:
    /// - coder: 系统归档来源。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：长路径和多行参数保持全文可编辑，视觉容器不截断实际模板。
    /// 参数说明:
    /// - text: 当前完整字段编辑器。
    /// - label: 原生辅助功能名称。
    /// 返回：独立滚动的纯文本输入容器。
    private func area(_ text: NSTextView, label: String) -> NSScrollView {
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 4)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        text.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        return scroll
    }

    /// 业务作用：明确选择另一份定义或新建时才替换表单，不沿后台刷新覆盖用户草稿。
    /// 参数说明:
    /// - command: 当前明确选择的完整定义，空值建立新的未保存输入。
    /// 返回：停止旧捕获并显示对应完整字段，不保存或执行。
    func load(_ command: NamedRunCommand?) {
        shortcut.stopCapture()
        name.stringValue = command?.name ?? ""
        program.string = command?.executable ?? "/usr/bin/printf"
        directory.string = command?.directory ?? ""
        shortcut.shortcut = command?.shortcut
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            arguments.string = String(
                decoding: try encoder.encode(command?.arguments ?? ["%s\n", "${word}"]),
                as: UTF8.self
            )
        }
        catch {
            arguments.string = "[]"
            onError?(error.localizedDescription)
        }
    }

    /// 业务作用：点击保存或预览时一次固定全部字段，未解析 JSON 不在主线程建立参数数组。
    /// 参数说明:
    /// - id: 当前明确选择的原配置身份。
    /// 返回：完整不可变表单快照，不截断字段或执行模板。
    func draft(id: UUID?) -> RunCommandDraft {
        shortcut.stopCapture()
        return RunCommandDraft(
            id: id,
            name: name.stringValue,
            executable: program.string,
            argumentsJSON: arguments.string,
            directory: directory.string,
            shortcut: shortcut.shortcut
        )
    }

    /// 业务作用：关闭面板释放明确录制的局部键盘监听，后续窗口不会被旧表单截获。
    /// 参数说明: 无。
    /// 返回：停止实际捕获，保留当前草稿组合。
    func stopCapture() {
        shortcut.stopCapture()
    }

    /// 业务作用：草稿可继续查看，只有当前具有写入资格时允许改变配置字段。
    /// 参数说明:
    /// - enabled: 当前是否允许配置编辑。
    /// 返回：完整表单与捕获入口采用一致权限。
    func setEditing(_ enabled: Bool) {
        name.isEditable = enabled
        program.isEditable = enabled
        arguments.isEditable = enabled
        directory.isEditable = enabled
        shortcut.isEnabled = enabled
        clear.isEnabled = enabled
    }

    /// 业务作用：原生字段的新输入立即撤销旧的预览准备资格。
    /// 参数说明:
    /// - notification: 名称字段的真实编辑通知。
    /// 返回：通知管理层当前草稿已改变。
    func controlTextDidChange(_ notification: Notification) {
        onEdit?()
    }

    /// 业务作用：程序、目录或参数原文改变后不能继续执行旧预览。
    /// 参数说明:
    /// - notification: 当前完整文本字段的真实编辑通知。
    /// 返回：撤销先前准备而不自动保存新输入。
    func textDidChange(_ notification: Notification) {
        onEdit?()
    }

    /// 业务作用：清空绑定只改变当前草稿，保存前不会移除已生效命令。
    /// 参数说明: 无。
    /// 返回：当前捕获为空并通知草稿改变。
    @objc private func clearShortcut() {
        guard clear.isEnabled else {
            return
        }
        shortcut.stopCapture()
        shortcut.shortcut = nil
        onEdit?()
    }
}
