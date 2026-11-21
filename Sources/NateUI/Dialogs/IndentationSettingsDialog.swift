import AppKit
import NateCore

@MainActor
public enum IndentationSettingsDialog {
    /// 业务作用：自动缩进和前导空白退格通过完整表单确认，草稿不提前改变任何视图或正文。
    /// 参数说明:
    /// - initial: 打开表单时的完整规则。
    /// - warning: 原偏好无法完整读取时的持续说明。
    /// 返回：明确应用时提供完整规则，取消返回空且不写入偏好。
    public static func choose(initial: IndentationSettings, warning: String?) -> IndentationSettings? {
        let mode = NSPopUpButton(
            frame: .zero,
            pullsDown: false
        )
        mode.setAccessibilityLabel("自动缩进模式")
        for value in AutomaticIndentation.allCases {
            mode.addItem(withTitle: title(for: value))
            mode.lastItem?.representedObject = value.rawValue
        }
        mode.selectItem(withTitle: title(for: initial.automatic))
        let backspace = NSButton(
            checkboxWithTitle: "普通光标在前导空白中按 Tab 停靠位退格",
            target: nil,
            action: nil
        )
        backspace.state = initial.backspaceUnindents ? .on : .off
        let note = NSTextField(
            wrappingLabelWithString:
                "关闭自动缩进时，新行不生成继承缩进；继承模式分别读取每个插入点之前的原行空白。退格选项只作用于普通空光标的前导空格与 Tab，采用对应语言的 Tab 宽度。矩形和虚拟行尾保留原列删除语义，正文中的退格仍按完整字形处理。改变设置不会转换已有空白。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480
        let status = NSTextField(wrappingLabelWithString: warning ?? "")
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 480
        let row = NSStackView(views: [NSTextField(labelWithString: "Return 自动缩进"), mode])
        row.spacing = 10
        let form = NSStackView(views: [row, backspace, note, status])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.widthAnchor.constraint(equalToConstant: 480).isActive = true
        note.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form)
        let alert = NSAlert()
        alert.messageText = "自动缩进与退格"
        alert.informativeText = "全局输入策略在所有克隆视图生效，Tab 停靠宽度仍按各文档语言独立配置。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(
                x: 8,
                y: 8,
                width: 480,
                height: max(200, form.fittingSize.height)
            )
            background.frame = NSRect(
                x: 0,
                y: 0,
                width: 496,
                height: form.frame.height + 16
            )
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            guard let raw = mode.selectedItem?.representedObject as? String,
                let automatic = AutomaticIndentation(rawValue: raw)
            else {
                status.stringValue = "自动缩进模式无效，请重新选择完整规则。"
                continue
            }
            return IndentationSettings(
                automatic: automatic,
                backspaceUnindents: backspace.state == .on
            )
        }
    }

    /// 业务作用：原生选项显示当前可执行模式，界面名称不作为持久化身份。
    /// 参数说明:
    /// - mode: 当前明确支持的自动缩进方式。
    /// 返回：对应的中文名称，保存仍使用枚举原始身份。
    private static func title(for mode: AutomaticIndentation) -> String {
        switch mode {
        case .disabled: return "关闭自动缩进"
        case .inherit: return "继承插入点之前的原行缩进"
        }
    }
}
