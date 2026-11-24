import AppKit
import NatePlatform

struct AutomaticCompletionOptions: Sendable {
    static let signaturePreferenceKey = "completion.signatureAuto"

    let words: Bool
    let signatures: Bool

    /// 业务作用：已有自动补全偏好继续决定尚未单独设置的参数提示；新设置可独立控制两种呈现。
    /// 参数说明:
    /// - defaults: 当前应用实际连接的偏好域。
    /// 返回：本次输入或表单采用的两个自动触发状态。
    init(defaults: UserDefaults) {
        words =
            defaults.object(forKey: "completion.enabled") == nil
            || defaults.bool(forKey: "completion.enabled")
        signatures =
            defaults.object(forKey: Self.signaturePreferenceKey) == nil
            ? words : defaults.bool(forKey: Self.signaturePreferenceKey)
    }
}

extension ApplicationController {
    /// 业务作用：候选、参数提示及确认按键独立配置，同一偏好来源通过复验后才应用整份设置。
    /// 参数说明: 无。
    /// 返回：完整验证后一次发布设置，取消保留原配置。
    func showAssistancePreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let defaults = configurationDefaults()
        let signatureKey = AutomaticCompletionOptions.signaturePreferenceKey
        let keys = [
            "completion.enabled", signatureKey, "completion.words", "completion.language", "completion.tab",
            "completion.enter", "completion.threshold",
        ]
        let source = keys.map { defaults.object(forKey: $0) as? NSObject }
        let generation = userConfiguration.generation
        let automatic = AutomaticCompletionOptions(defaults: defaults)
        let enabled = NSButton(checkboxWithTitle: "输入后自动显示补全候选", target: nil, action: nil)
        enabled.state = automatic.words ? .on : .off
        let signature = NSButton(checkboxWithTitle: "输入后自动显示函数参数提示", target: nil, action: nil)
        signature.state = automatic.signatures ? .on : .off
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
            enabled, words, language, signature,
            NSTextField(labelWithString: "自动触发字符数（1–20）"), threshold, tab, enter,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 235)
        let alert = NSAlert()
        alert.messageText = "补全与参数提示"
        alert.informativeText = "候选和参数提示均可手动打开。文档单词扫描最多取光标周边 16 MiB，候选最多 200 项。"
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
        // 表单期间可能切换或导入偏好，旧草稿只有在原设置和输入来源仍一致时才能发布。
        guard !closing, mainWindow?.hasMarkedEditorInput != true, configurationDefaults() === defaults,
            userConfiguration.generation == generation,
            keys.map({ defaults.object(forKey: $0) as? NSObject }) == source
        else {
            mainWindow?.status.stringValue = "补全设置已改变，旧表单未应用，请重新打开。"
            return
        }
        cancelCompletion()
        userConfiguration.generation = UUID()
        defaults.set(enabled.state == .on, forKey: "completion.enabled")
        defaults.set(signature.state == .on, forKey: signatureKey)
        defaults.set(words.state == .on, forKey: "completion.words")
        defaults.set(language.state == .on, forKey: "completion.language")
        defaults.set(tab.state == .on, forKey: "completion.tab")
        defaults.set(enter.state == .on, forKey: "completion.enter")
        defaults.set(count, forKey: "completion.threshold")
    }
}
