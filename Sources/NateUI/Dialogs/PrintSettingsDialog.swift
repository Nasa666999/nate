import AppKit
import NateCore

@MainActor
public enum PrintSettingsDialog {
    /// 业务作用：完整配置独立打印呈现，取消和非法输入不改变已保存参数。
    /// 参数说明:
    /// - initial: 当前已验证的实际配置。
    /// - warning: 原归档读取失败等需要保留给使用者的原因。
    /// 返回：明确应用且全部字段合法时提供完整配置；取消为空。
    public static func choose(initial: PrintSettings, warning: String? = nil) -> PrintSettings? {
        PrintSettingsForm(initial: initial, warning: warning).run()
    }
}

@MainActor
private final class PrintSettingsForm: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let color = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let scale = NSTextField()
    let numbers = NSButton(
        checkboxWithTitle: "打印原逻辑行号",
        target: nil,
        action: nil
    )
    let feeds = NSButton(
        checkboxWithTitle: "将 FF 作为分页",
        target: nil,
        action: nil
    )
    let margins: [NSTextField]
    let header: PrintDecorationFields
    let footer: PrintDecorationFields
    let variable = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let feedback = NSTextField(wrappingLabelWithString: "")
    weak var lastField: NSTextField?
    var lastCaret = NSRange(
        location: 0,
        length: 0
    )

    /// 业务作用：所有实际打印参数在同一表单完整保留，不把六个模板区域拼成摘要输入。
    /// 参数说明:
    /// - initial: 当前完整合法配置。
    /// - warning: 读取旧配置失败的可见说明。
    /// 返回：尚未应用任何设置的独立原生表单。
    init(initial: PrintSettings, warning: String?) {
        margins = [initial.marginTop, initial.marginBottom, initial.marginLeft, initial.marginRight].map {
            NSTextField(string: String($0))
        }
        header = PrintDecorationFields(initial.header)
        footer = PrintDecorationFields(initial.footer)
        super.init()
        alert.messageText = "打印设置"
        alert.informativeText = "打印使用独立正文快照；纸张、方向、页码范围、份数和系统 PDF 输出在打印面板选择。"
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        color.addItems(withTitles: ["文档颜色", "反色", "黑字白纸", "去除背景颜色"])
        color.selectItem(at: PrintColorMode.allCases.firstIndex(of: initial.color) ?? 2)
        scale.stringValue = String(initial.fontScale * 100)
        numbers.state = initial.lineNumbers ? .on : .off
        feeds.state = initial.formFeedPageBreaks ? .on : .off
        variable.addItems(withTitles: PrintTemplate.variables)
        let insert = NSButton(
            title: "插入变量",
            target: self,
            action: #selector(insertVariable)
        )
        for field in header.templates + footer.templates {
            field.delegate = self
        }
        feedback.stringValue = warning ?? "各模板区最多 4 KiB，不含换行；$$ 表示字面美元符。变量值不会被再次解释。"
        feedback.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        feedback.preferredMaxLayoutWidth = 680
        let marginRow = NSStackView()
        marginRow.spacing = 8
        for (name, field) in zip(["上", "下", "左", "右"], margins) {
            field.setAccessibilityLabel("打印" + name + "页边距毫米")
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            marginRow.addArrangedSubview(NSTextField(labelWithString: name))
            marginRow.addArrangedSubview(field)
        }
        let modes = NSStackView(views: [color, NSTextField(labelWithString: "正文缩放 %"), scale])
        modes.spacing = 10
        scale.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let flags = NSStackView(views: [numbers, feeds])
        flags.spacing = 24
        let variables = NSStackView(views: [NSTextField(labelWithString: "模板变量"), variable, insert])
        variables.spacing = 8
        let note = NSTextField(
            wrappingLabelWithString:
                "页眉与页脚各分左、中、右三个独立区域。文件信息与日期时间固定在作业开始时；页码使用实际分页。长内容在所属区域内显示，不覆盖正文或其它区域。"
        )
        note.preferredMaxLayoutWidth = 680
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            modes, flags, NSTextField(labelWithString: "页边距（毫米，0–100）"), marginRow,
            NSTextField(labelWithString: "页眉"), header, NSTextField(labelWithString: "页脚"), footer,
            variables, note, feedback,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [header, footer, note, feedback] {
            view.widthAnchor.constraint(equalToConstant: 680).isActive = true
        }
        stack.frame = NSRect(
            x: 0,
            y: 0,
            width: 680,
            height: max(460, stack.fittingSize.height)
        )
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.frame = NSRect(
            x: 0,
            y: 0,
            width: stack.frame.width + 16,
            height: stack.frame.height + 16
        )
        stack.setFrameOrigin(
            NSPoint(
                x: 8,
                y: 8
            )
        )
        stack.autoresizingMask = [.width, .height]
        background.addSubview(stack)
        alert.accessoryView = background
    }

    /// 业务作用：仅完整有效表单能替换实际配置，错误反馈保留全部原输入。
    /// 参数说明: 无。
    /// 返回：明确应用的完整设置；取消不产生配置或正文副作用。
    func run() -> PrintSettings? {
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                return try PrintSettings(
                    color: PrintColorMode.allCases[color.indexOfSelectedItem],
                    fontScale: number(scale, name: "正文缩放") / 100,
                    lineNumbers: numbers.state == .on,
                    formFeedPageBreaks: feeds.state == .on,
                    marginTop: number(margins[0], name: "上页边距"),
                    marginBottom: number(margins[1], name: "下页边距"),
                    marginLeft: number(margins[2], name: "左页边距"),
                    marginRight: number(margins[3], name: "右页边距"),
                    header: header.value(),
                    footer: footer.value()
                )
            }
            catch {
                feedback.stringValue = error.localizedDescription
                feedback.textColor = .systemRed
            }
        }
        return nil
    }

    /// 业务作用：数值必须完整解析，非法页边距不能被控件默认为零后写入实际配置。
    /// 参数说明:
    /// - field: 原始数值字段。
    /// - name: 使用者看到的参数名称。
    /// 返回：有限的明确数字；缺失或非数字输入失败。
    private func number(_ field: NSTextField, name: String) throws -> Double {
        guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            value.isFinite
        else {
            throw NateError.message(name + "必须为有限数字，小数使用点号。")
        }
        return value
    }

    /// 业务作用：变量按钮只作用于最近实际编辑的模板及其真实 UTF-16 选择。
    /// 参数说明:
    /// - notification: 当前原生字段编辑事件。
    /// 返回：保存模板目标和仍合法的插入位置，不改动其它配置字段。
    private func remember(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            (header.templates + footer.templates).contains(where: {
                $0 === field
            })
        else {
            return
        }
        if lastField !== field {
            lastCaret = NSRange(
                location: field.stringValue.utf16.count,
                length: 0
            )
        }
        lastField = field
        if let editor = field.currentEditor() as? NSTextView {
            lastCaret = editor.selectedRange()
        }
    }

    /// 业务作用：开始编辑模板时固定变量按钮的实际目标。
    /// 参数说明:
    /// - notification: 原生开始编辑通知。
    /// 返回：记录真实模板输入，不修改字符串。
    func controlTextDidBeginEditing(_ notification: Notification) {
        remember(notification)
    }

    /// 业务作用：模板输入后保持最新插入位置，变量不会按旧文本长度覆盖后来输入。
    /// 参数说明:
    /// - notification: 原生文字变更通知。
    /// 返回：更新当前字段的完整选择证据。
    func controlTextDidChange(_ notification: Notification) {
        remember(notification)
    }

    /// 业务作用：按钮获得焦点前保留模板最后的实际选区。
    /// 参数说明:
    /// - notification: 原生结束编辑通知。
    /// 返回：保留最后合法插入位置；不把字体或数值字段作为模板。
    func controlTextDidEndEditing(_ notification: Notification) {
        remember(notification)
    }

    /// 业务作用：在模板当前选择插入一个完整受支持变量，不切开代理项或截断原文。
    /// 参数说明: 无。
    /// 返回：目标和容量有效时完整替换选择，其它情况保留输入并显示原因。
    @objc private func insertVariable() {
        let field = lastField ?? header.templates[0]
        if let editor = field.currentEditor() as? NSTextView {
            lastCaret = editor.selectedRange()
        }
        let original = field.stringValue
        guard let range = Range(lastCaret, in: original), let key = variable.selectedItem?.title else {
            feedback.stringValue = "原模板选择已改变，请重新选择变量插入位置。"
            return
        }
        let value = "$(" + key + ")"
        let result = original.replacingCharacters(in: range, with: value)
        guard result.utf8.count <= 4096 else {
            feedback.stringValue = "插入后模板超过 4 KiB，原输入保持不变。"
            return
        }
        field.stringValue = result
        lastField = field
        lastCaret = NSRange(
            location: lastCaret.location + value.utf16.count,
            length: 0
        )
        field.window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.setSelectedRange(lastCaret)
    }
}

@MainActor
private final class PrintDecorationFields: NSView {
    let templates = [NSTextField(), NSTextField(), NSTextField()]
    let font = NSComboBox()
    let size = NSTextField()
    let bold = NSButton(
        checkboxWithTitle: "粗体",
        target: nil,
        action: nil
    )
    let italic = NSButton(
        checkboxWithTitle: "斜体",
        target: nil,
        action: nil
    )

    /// 业务作用：页眉与页脚分别保留三栏原文和完整字体参数。
    /// 参数说明:
    /// - value: 当前已验证装饰配置。
    /// 返回：完整显示原始字段、不立即改变实际配置的输入区域。
    init(_ value: PrintDecoration) {
        super.init(frame: .zero)
        for (index, text) in [value.left, value.middle, value.right].enumerated() {
            templates[index].stringValue = text
            templates[index].placeholderString = ["左侧", "中间", "右侧"][index]
            templates[index].setAccessibilityLabel(["左侧", "中间", "右侧"][index] + "打印模板")
        }
        font.addItems(withObjectValues: NSFontManager.shared.availableFontFamilies.sorted())
        font.completes = true
        font.placeholderString = "留空沿用正文家族"
        font.stringValue = value.fontName
        size.stringValue = String(value.fontSize)
        bold.state = value.bold ? .on : .off
        italic.state = value.italic ? .on : .off
        let texts = NSStackView(views: templates)
        texts.distribution = .fillEqually
        texts.spacing = 8
        let fonts = NSStackView(views: [font, NSTextField(labelWithString: "字号"), size, bold, italic])
        fonts.spacing = 8
        let stack = NSStackView(views: [texts, fonts])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            texts.widthAnchor.constraint(equalTo: widthAnchor),
            fonts.widthAnchor.constraint(equalTo: widthAnchor),
            font.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            size.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    /// 业务作用：打印字段仅由当前实际配置建立，不恢复外部界面归档。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：装饰全文与字体一并验证，不能静默替换明确但不可用的字体名称。
    /// 参数说明: 无。
    /// 返回：完整合法装饰；非法字号、模板或不可用字体失败并保留表单。
    func value() throws -> PrintDecoration {
        guard let points = Double(size.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            points.isFinite, (6...72).contains(points),
            font.stringValue.isEmpty
                || NSFont(
                    name: font.stringValue,
                    size: points
                ) != nil
        else {
            throw NateError.message("页眉页脚需要有效字号与已安装字体，字体可留空。")
        }
        return try PrintDecoration(
            left: templates[0].stringValue,
            middle: templates[1].stringValue,
            right: templates[2].stringValue,
            fontName: font.stringValue,
            fontSize: points,
            bold: bold.state == .on,
            italic: italic.state == .on
        )
    }
}
