import AppKit
import NateCore

@MainActor
public enum WordBoundaryDialog {
    /// 业务作用：用户在独立草稿中启停附加词字符，默认 Unicode 规则和原字符顺序始终保留。
    /// 参数说明:
    /// - initial: 当前完整词规则。
    /// - warning: 原归档无法读取时的持续说明。
    /// 返回：明确应用且全部字符合法时返回完整规则，取消不保存，错误可在同一草稿更正。
    public static func choose(initial: WordBoundarySettings, warning: String?) -> WordBoundarySettings? {
        let enabled = NSButton(checkboxWithTitle: "启用附加词字符", target: nil, action: nil)
        enabled.state = initial.useCustom ? .on : .off
        let characters = NSTextField(string: initial.additionalCharacters)
        characters.setAccessibilityLabel("附加词字符")
        let note = NSTextField(
            wrappingLabelWithString:
                "默认词字符包含字母、数字、组合标记和下划线。附加字符原样读取，不解释反斜杠转义；空格或 Tab 加入后会把相邻内容视为同一词。关闭时保留草稿。"
        )
        note.preferredMaxLayoutWidth = 460
        note.textColor = .secondaryLabelColor
        let status = NSTextField(wrappingLabelWithString: warning ?? "")
        status.preferredMaxLayoutWidth = 460
        status.textColor = .systemOrange
        let form = NSStackView(views: [
            enabled, NSTextField(labelWithString: "附加词字符（最多 256 个）"), characters, note, status,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.widthAnchor.constraint(equalToConstant: 460).isActive = true
        characters.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form)
        let alert = NSAlert()
        alert.messageText = "词字符与边界"
        alert.informativeText = "选词、按词移动与普通整词查找使用同一规则；正则表达式字符类保持独立。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(x: 8, y: 8, width: 460, height: max(190, form.fittingSize.height))
            background.setFrameSize(NSSize(width: 476, height: form.frame.height + 16))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            alert.window.makeFirstResponder(nil)
            do {
                return try WordBoundarySettings(
                    useCustom: enabled.state == .on,
                    additionalCharacters: characters.stringValue
                )
            }
            catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
