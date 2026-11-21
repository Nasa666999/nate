import AppKit
import NateCore

@MainActor
public enum WebSearchDialog {
    /// 业务作用：独立草稿配置明确执行网络搜索时的目标，预览只构造网址而不访问网络。
    /// 参数说明:
    /// - initial: 完整搜索引擎与原模板。
    /// - warning: 原归档不能读取时持续展示的原因。
    /// 返回：明确应用且模板完整合法时交付设置，取消返回空。
    public static func choose(initial: WebSearchSettings, warning: String?) -> WebSearchSettings? {
        let form = WebSearchForm(initial: initial, warning: warning)
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form.stack)
        let alert = NSAlert()
        alert.messageText = "搜索引擎"
        alert.informativeText = "编辑菜单或正文右键菜单可搜索单一连续选区；没有选区时搜索光标所在的完整词。只有明确执行搜索才交给默认浏览器。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.stack.frame = NSRect(x: 8, y: 8, width: 480, height: max(280, form.stack.fittingSize.height))
            background.setFrameSize(NSSize(width: 496, height: form.stack.frame.height + 16))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            alert.window.makeFirstResponder(nil)
            do {
                return try form.settings()
            }
            catch {
                form.status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class WebSearchForm: NSObject, NSTextFieldDelegate {
    let stack = NSStackView()
    let engine = NSPopUpButton()
    let template: NSTextField
    let preview = NSTextField(wrappingLabelWithString: "")
    let status: NSTextField

    /// 业务作用：引擎切换只更新独立模板草稿和固定示例，不读取正文或发起联网。
    /// 参数说明:
    /// - initial: 完整原引擎与模板草稿。
    /// - warning: 原归档无法读取时的说明。
    /// 返回：可切换引擎、编辑自定义模板并查看有界示例的表单。
    init(initial: WebSearchSettings, warning: String?) {
        template = NSTextField(string: initial.customTemplate)
        status = NSTextField(wrappingLabelWithString: warning ?? "")
        super.init()
        engine.addItems(withTitles: [
            "Google", "DuckDuckGo", "Bing（使用 DuckDuckGo）", "Yahoo", "Stack Overflow", "自定义",
        ])
        engine.selectItem(at: WebSearchEngine.allCases.firstIndex(of: initial.engine) ?? 0)
        engine.target = self
        engine.action = #selector(updateEngine)
        engine.setAccessibilityLabel("网络搜索引擎")
        template.setAccessibilityLabel("自定义搜索模板")
        template.placeholderString = "https://example.com/search?q=$(CURRENT_WORD)"
        template.delegate = self
        preview.setAccessibilityLabel("网络搜索网址预览")
        preview.isSelectable = true
        preview.maximumNumberOfLines = 3
        preview.lineBreakMode = .byTruncatingMiddle
        preview.preferredMaxLayoutWidth = 480
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 480
        let note = NSTextField(
            wrappingLabelWithString:
                "自定义模板最多 4 KiB，仅支持固定 HTTP(S) 目标及 $(CURRENT_WORD)。查询按原始 UTF-8 百分号编码，不解释正文中的变量。最多 16 KiB 原文；超限时完整拒绝，不能搜索被截断的内容。切换引擎保留自定义草稿。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in [
            NSTextField(labelWithString: "引擎"), engine,
            NSTextField(labelWithString: "自定义模板"), template,
            NSTextField(labelWithString: "固定示例的网址预览"), preview, note, status,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        template.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateEngine()
    }

    /// 业务作用：固定菜单身份决定当前引擎，自定义模式才允许编辑模板。
    /// 参数说明: 无。
    /// 返回：更新可编辑状态与示例，不删除停用草稿或保存偏好。
    @objc private func updateEngine() {
        template.isEnabled = engine.indexOfSelectedItem == WebSearchEngine.allCases.firstIndex(of: .custom)
        updatePreview()
    }

    /// 业务作用：原模板文字变化只刷新同一固定示例，不使用用户正文作为预览查询。
    /// 参数说明:
    /// - notification: 模板草稿的文本编辑通知。
    /// 返回：更新内存预览，不打开浏览器。
    func controlTextDidChange(_ notification: Notification) {
        updatePreview()
    }

    /// 业务作用：完整验证固定引擎和原模板，未选中的菜单项不能冒充默认引擎。
    /// 参数说明: 无。
    /// 返回：合法完整设置，失败保留原草稿并说明原因。
    func settings() throws -> WebSearchSettings {
        guard WebSearchEngine.allCases.indices.contains(engine.indexOfSelectedItem) else {
            throw NateError.message("请选择网络搜索引擎。")
        }
        return try WebSearchSettings(
            engine: WebSearchEngine.allCases[engine.indexOfSelectedItem],
            customTemplate: template.stringValue
        )
    }

    /// 业务作用：预览只展示固定查询的完整目标，有界行数避免长模板把操作按钮挤出窗口。
    /// 参数说明: 无。
    /// 返回：显示网址或草稿原因，全部计算均不访问网络或持久化。
    private func updatePreview() {
        do {
            preview.stringValue = try settings().url(for: "示例查询 e\u{301} &").absoluteString
        }
        catch {
            preview.stringValue = error.localizedDescription
        }
    }
}
