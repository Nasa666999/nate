import AppKit
import NateCore

@MainActor
public final class TabSettingsDialog: NSObject {
    private let inherited = NSButton(checkboxWithTitle: "当前语言继承全局默认", target: nil, action: nil)
    private let globalWidth: NSTextField
    private let globalSpaces: NSButton
    private let languageWidth: NSTextField
    private let languageSpaces: NSButton

    /// 业务作用：表单固定完整初值，编辑草稿不提前改变正文或当前语言规则。
    /// 参数说明:
    /// - settings: 打开表单时的完整配置。
    /// - language: 本次明确配置的稳定语言身份。
    /// 返回：全局与语言字段均保留原值，继承状态控制覆盖字段是否可编辑。
    private init(settings: LanguageTabSettings, language: String) {
        globalWidth = NSTextField(string: String(settings.defaults.width))
        globalSpaces = NSButton(checkboxWithTitle: "Tab 按键与增加缩进使用空格", target: nil, action: nil)
        globalSpaces.state = settings.defaults.useSpaces ? .on : .off
        let effective = settings.settings(for: language)
        languageWidth = NSTextField(string: String(effective.width))
        languageSpaces = NSButton(checkboxWithTitle: "Tab 按键与增加缩进使用空格", target: nil, action: nil)
        languageSpaces.state = effective.useSpaces ? .on : .off
        super.init()
        inherited.state = settings.languages[language] == nil ? .on : .off
        inherited.target = self
        inherited.action = #selector(updateInheritance)
        globalWidth.setAccessibilityLabel("全局 Tab 宽度")
        languageWidth.setAccessibilityLabel("当前语言 Tab 宽度")
        globalSpaces.setAccessibilityLabel("全局 Tab 使用空格")
        languageSpaces.setAccessibilityLabel("当前语言 Tab 使用空格")
        updateInheritance()
    }

    /// 业务作用：继承时停用覆盖输入，尚未应用的语言草稿保留以便切换回独立规则。
    /// 参数说明: 无。
    /// 返回：只改变字段可编辑性，不保存或重写配置。
    @objc private func updateInheritance() {
        languageWidth.isEnabled = inherited.state != .on
        languageSpaces.isEnabled = inherited.state != .on
    }

    /// 业务作用：原生表单完整确认全局及单语言覆盖，非法草稿留在同一窗口供继续编辑。
    /// 参数说明:
    /// - initial: 已验证的完整配置，其它语言覆盖项继续保留。
    /// - language: 本次固定的语言身份。
    /// - name: 当前语言的显示名称。
    /// - warning: 未能读取原归档时的持续说明。
    /// 返回：明确应用且全部字段合法时提供完整新配置，取消返回空。
    public static func choose(
        initial: LanguageTabSettings,
        language: String,
        name: String,
        warning: String?
    ) -> LanguageTabSettings? {
        let controller = TabSettingsDialog(settings: initial, language: language)
        let note = NSTextField(
            wrappingLabelWithString:
                "宽度为 1–32 列。空格 Tab 按完整字素列推进到下个停靠位，多光标逐项计算。改变规则不转换已有 Tab；当前语言取消继承后独立保存，其它语言覆盖项保留。"
        )
        note.preferredMaxLayoutWidth = 480
        note.textColor = .secondaryLabelColor
        let status = NSTextField(wrappingLabelWithString: warning ?? "")
        status.preferredMaxLayoutWidth = 480
        status.textColor = .systemOrange
        let form = NSStackView(views: [
            NSTextField(labelWithString: "全局默认"),
            widthRow(controller.globalWidth), controller.globalSpaces,
            NSTextField(labelWithString: "当前语言：" + name), controller.inherited,
            widthRow(controller.languageWidth), controller.languageSpaces, note, status,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
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
        alert.messageText = "Tab 与缩进"
        alert.informativeText = "停靠间距、Tab 输入和增加缩进共同使用语言规则；打印与列编辑使用相同列宽。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(
                x: 8,
                y: 8,
                width: 480,
                height: max(280, form.fittingSize.height)
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
            alert.window.makeFirstResponder(nil)
            do {
                let defaults = try read(width: controller.globalWidth, spaces: controller.globalSpaces)
                var languages = initial.languages
                if controller.inherited.state == .on {
                    languages.removeValue(forKey: language)
                }
                else {
                    languages[language] = try read(
                        width: controller.languageWidth,
                        spaces: controller.languageSpaces
                    )
                }
                return try LanguageTabSettings(defaults: defaults, languages: languages)
            }
            catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    /// 业务作用：两组宽度字段保留相同尺寸和明确标签，屏幕与辅助功能均能识别作用范围。
    /// 参数说明:
    /// - field: 当前范围的宽度草稿。
    /// 返回：只组织原生布局，不解释或保存字段内容。
    private static func widthRow(_ field: NSTextField) -> NSStackView {
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [NSTextField(labelWithString: "Tab 宽度"), field])
        row.spacing = 10
        return row
    }

    /// 业务作用：字段必须完整为十进制整数，空白、符号和越界值不能被默认数值转换掩盖。
    /// 参数说明:
    /// - width: 当前范围的完整宽度草稿。
    /// - spaces: 新输入是否生成空格。
    /// 返回：全部合法时产生规则，否则明确拒绝并保留草稿。
    private static func read(width: NSTextField, spaces: NSButton) throws -> TabSettings {
        let raw = width.stringValue
        guard !raw.isEmpty, raw.utf8.count <= 2,
            raw.utf8.allSatisfy({
                (48...57).contains($0)
            }), let value = Int(raw)
        else {
            throw NateError.message("Tab 宽度必须是 1 到 32 的完整十进制整数。")
        }
        return try TabSettings(width: value, useSpaces: spaces.state == .on)
    }
}
