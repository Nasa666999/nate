import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：自动补全的触发和确认分别配置，关闭自动触发不关闭手动入口。
    /// 参数说明: 无。
    /// 返回：完整验证后一次发布设置，取消保留原配置。
    func showAssistancePreferences() {
        let defaults = configurationDefaults()
        let enabled = NSButton(checkboxWithTitle: "输入后自动显示补全与参数提示", target: nil, action: nil)
        enabled.state =
            defaults.object(forKey: "completion.enabled") == nil
                || defaults.bool(forKey: "completion.enabled") ? .on : .off
        let words = NSButton(checkboxWithTitle: "自动候选包含文档单词", target: nil, action: nil)
        words.state =
            defaults.object(forKey: "completion.words") == nil || defaults.bool(forKey: "completion.words")
            ? .on : .off
        let language = NSButton(checkboxWithTitle: "自动候选包含语言关键字与函数", target: nil, action: nil)
        language.state =
            defaults.object(forKey: "completion.language") == nil
                || defaults.bool(forKey: "completion.language") ? .on : .off
        let tab = NSButton(checkboxWithTitle: "Tab 确认候选", target: nil, action: nil)
        tab.state =
            defaults.object(forKey: "completion.tab") == nil || defaults.bool(forKey: "completion.tab")
            ? .on : .off
        let enter = NSButton(checkboxWithTitle: "Enter 确认候选", target: nil, action: nil)
        enter.state =
            defaults.object(forKey: "completion.enter") == nil || defaults.bool(forKey: "completion.enter")
            ? .on : .off
        let threshold = NSTextField(
            string: String(
                defaults.object(forKey: "completion.threshold") == nil
                    ? 2 : defaults.integer(forKey: "completion.threshold")
            )
        )
        let stack = NSStackView(views: [
            enabled, words, language,
            NSTextField(labelWithString: "自动触发字符数（1–20）"), threshold, tab, enter,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 210)
        let alert = NSAlert()
        alert.messageText = "补全与参数提示"
        alert.informativeText = "文档单词扫描最多取光标周边 16 MB，候选最多 200 项；达到预算会说明范围。路径只通过手动命令枚举。"
        alert.accessoryView = stack
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard let count = Int(threshold.stringValue), (1...20).contains(count) else {
            SystemIntegration.alert("触发字符数无效", "请输入 1 到 20 的整数。设置保持原状。")
            return
        }
        cancelCompletion()
        defaults.set(enabled.state == .on, forKey: "completion.enabled")
        defaults.set(words.state == .on, forKey: "completion.words")
        defaults.set(language.state == .on, forKey: "completion.language")
        defaults.set(tab.state == .on, forKey: "completion.tab")
        defaults.set(enter.state == .on, forKey: "completion.enter")
        defaults.set(count, forKey: "completion.threshold")
    }
}
