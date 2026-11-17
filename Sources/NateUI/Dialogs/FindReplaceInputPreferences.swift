import AppKit
import NateSearch

extension FindReplaceWindow {
    /// 业务作用：只对真实连续选区开放批量选区范围，自动阈值为零时保留用户勾选意图。
    /// 参数说明:
    /// - context: 当前焦点文档和视图生成的范围证据。
    /// 返回：选区控件可用性更新；自动勾选状态实际变化时提交配置，不改变正文或选区。
    public func applySelectionContext(_ context: SearchPresentationContext) {
        // 多选区和虚拟列不能被一个连续范围冒充；禁用控件不等于替用户清除手动设置。
        selection.isEnabled = context.selectionEligible
        if let checked = context.selectionOnly {
            let state: NSControl.StateValue = checked ? .on : .off
            if state != selection.state {
                selection.state = state
                stateChanged()
            }
        }
    }

    /// 业务作用：通过独立设置控制选区填入、光标词、多行内容与选区内自动勾选，不混淆字节和字符阈值。
    /// 参数说明: 无。
    /// 返回：确认且参数有效后发布偏好并复验当前选区；取消或无效整数保持原设置。
    @objc func showInputPreferences() {
        let alert = NSAlert()
        alert.messageText = "搜索输入设置"
        alert.informativeText = "字符按 Unicode 标量计数，组合标记单独计数，emoji 不按 UTF-16 两个单元计数。设置不改变正文选区。"
        let fill = NSButton(
            checkboxWithTitle: "从短选区自动填入查找内容",
            target: nil,
            action: nil
        )
        let word = NSButton(
            checkboxWithTitle: "无选区时自动填入光标单词",
            target: nil,
            action: nil
        )
        let multiline = NSButton(
            checkboxWithTitle: "允许自动填入多行选区",
            target: nil,
            action: nil
        )
        fill.state = presentationPreferences.fillFromSelection ? .on : .off
        word.state = presentationPreferences.fillFromWord ? .on : .off
        multiline.state = presentationPreferences.fillMultiline ? .on : .off
        let fillLimit = NSTextField(string: String(presentationPreferences.fillLimit))
        let threshold = NSTextField(string: String(presentationPreferences.selectionThreshold))
        let controls = NSStackView(views: [
            fill, word, multiline,
            NSTextField(labelWithString: "自动填入字符上限（1–262144）"), fillLimit,
            NSTextField(labelWithString: "选区内自动勾选字符阈值（0 为手动控制）"), threshold,
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 9
        controls.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        alert.accessoryView = controls
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        // 只有完整确认的偏好可以改变后续选区范围，关闭设置面板不能隐式发布勾选或填入规则。
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard let maximum = Int(fillLimit.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            let selected = Int(threshold.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            feedback.stringValue = "字符阈值必须填写整数，原设置保留。"
            return
        }
        var preferences = SearchPresentationPreferences()
        preferences.fillFromSelection = fill.state == .on
        preferences.fillFromWord = word.state == .on
        preferences.fillMultiline = multiline.state == .on
        preferences.fillLimit = maximum
        preferences.selectionThreshold = selected
        do {
            try preferences.validate()
            presentationPreferences = preferences
            onSelectionContextRequest?()
            stateChanged()
        }
        catch {
            feedback.stringValue = error.localizedDescription
        }
    }
}
