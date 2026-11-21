import AppKit
import NateCore

@MainActor
public enum DelimiterSelectionDialog {
    /// 业务作用：在独立草稿中配置分隔符，取消或校验失败不改变后续选择规则。
    /// 参数说明:
    /// - initial: 打开时固定的完整配置。
    /// - warning: 损坏或未知原归档的说明。
    /// 返回：明确应用且两端合法时返回完整配置；取消为空，非法输入可在原表单更正。
    public static func choose(
        initial: DelimiterSelectionSettings,
        warning: String?
    ) -> DelimiterSelectionSettings? {
        let opening = NSTextField(string: initial.opening)
        opening.setAccessibilityLabel("左分隔符")
        let closing = NSTextField(string: initial.closing)
        closing.setAccessibilityLabel("右分隔符")
        let entire = NSButton(checkboxWithTitle: "在整个文档查找（关闭时仅当前行）", target: nil, action: nil)
        entire.state = initial.entireDocument ? .on : .off
        let note = NSTextField(
            wrappingLabelWithString:
                "每端输入一个原始 Unicode 标量，不解释转义。不同符号按嵌套配对；相同符号选取两侧最近的符号。双引号紧接反斜杠时忽略。扫描不依赖语言或语法样式。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 460
        let status = NSTextField(wrappingLabelWithString: warning ?? "")
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 460
        let form = NSStackView(views: [
            NSTextField(labelWithString: "左分隔符"), opening,
            NSTextField(labelWithString: "右分隔符"), closing,
            entire, note, status,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.widthAnchor.constraint(equalToConstant: 460).isActive = true
        for field in [opening, closing] {
            field.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form)
        let alert = NSAlert()
        alert.messageText = "分隔符选择"
        alert.informativeText = "Command 双击或“搜索 → 选择配置分隔符内部”选择正文；预算不足时保留原选区。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(x: 8, y: 8, width: 460, height: max(260, form.fittingSize.height))
            background.setFrameSize(NSSize(width: 476, height: form.frame.height + 16))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            alert.window.makeFirstResponder(nil)
            do {
                return try DelimiterSelectionSettings(
                    opening: opening.stringValue,
                    closing: closing.stringValue,
                    entireDocument: entire.state == .on
                )
            }
            catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
