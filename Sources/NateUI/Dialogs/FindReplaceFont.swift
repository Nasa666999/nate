import AppKit

extension FindReplaceWindow {
    public var inputFontPreferences: SearchInputFont {
        inputFontConfiguration
    }

    /// 业务作用：独立调整四类查找输入与全文编辑字体，正文、输入原文和候选草稿保持各自状态。
    /// 参数说明:
    /// - preferences: 完整字体名称与字号。
    /// 返回：有效配置应用并进入持久化；缺失字体采用同字号系统等宽字体并提示，无效配置不改变控件。
    public func setInputFont(_ preferences: SearchInputFont) throws {
        try applyInputFont(preferences, notify: true)
    }

    /// 业务作用：统一恢复和用户设置的字体发布，先验证配置，再更新输入尺寸和窗口最小范围。
    /// 参数说明:
    /// - preferences: 已读取或由用户选择的完整字体配置。
    /// - notify: 是否把此次主动调整提交给设置保存入口。
    /// 返回：输入字段及已打开的全文编辑使用相同字体，布局随字体行高调整。
    func applyInputFont(_ preferences: SearchInputFont, notify: Bool) throws {
        // 非有限字号和无效名称必须在第一个字体或尺寸变化前拒绝，不能留下部分换字体的窗口。
        try preferences.validate()
        let selected = NSFontManager.shared.font(
            withFamily: preferences.family,
            traits: [],
            weight: 5,
            size: CGFloat(preferences.pointSize)
        )
        let font =
            selected
            ?? NSFont.monospacedSystemFont(
                ofSize: CGFloat(preferences.pointSize),
                weight: .regular
            )
        inputFontConfiguration = preferences
        for input in [query, replacement, directory, filters] {
            input.font = font
        }
        updateInputMinimumSize()
        window?.contentView?.layoutSubtreeIfNeeded()
        if selected == nil {
            feedback.stringValue = "指定输入字体不可用，当前使用同字号的系统等宽字体；字体偏好仍保留。"
        }
        else if notify {
            feedback.stringValue = "输入字体 · \(preferences.family) · \(preferences.pointSize) 点"
        }
        if notify {
            stateChanged()
        }
    }

    /// 业务作用：大字号增加字段行高时保留页签动作和反馈空间，不通过压缩输入控件隐藏内容。
    /// 参数说明: 无。
    /// 返回：最小高度随可见字段数量增加，已有窗口不足时保留上边缘并向下扩展，完整输入不变。
    func updateInputMinimumSize() {
        guard let window else {
            return
        }
        let rows: CGFloat = page == .files ? 4 : 2
        let height = 400 + rows * max(0, query.intrinsicContentSize.height - 28)
        var frame = window.frame
        window.minSize = NSSize(width: 750, height: height)
        if frame.height < height {
            frame.origin.y -= height - frame.height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }

    /// 业务作用：提供查找输入独立字体与字号的原生设置入口，不改正文显示或文本编码。
    /// 参数说明: 无。
    /// 返回：确认且配置有效后应用输入字体，取消保留当前字体和完整输入。
    @objc func showInputFont() {
        let alert = NSAlert()
        alert.messageText = "查找输入字体"
        alert.informativeText = "应用于查找、替换、目录、过滤条件及“编辑全文”。字号为 7–32 点，可填写小数。"
        let family = NSPopUpButton()
        var families = NSFontManager.shared.availableFontFamilies.sorted()
        if !families.contains(inputFontConfiguration.family) {
            families.insert(inputFontConfiguration.family, at: 0)
        }
        family.addItems(withTitles: families)
        family.selectItem(withTitle: inputFontConfiguration.family)
        let size = NSTextField(string: String(inputFontConfiguration.pointSize))
        let controls = NSStackView(views: [
            NSTextField(labelWithString: "字体"), family,
            NSTextField(labelWithString: "字号"), size,
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.frame = NSRect(x: 0, y: 0, width: 380, height: 130)
        alert.accessoryView = controls
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        // 仅明确应用的选择进入输入控件，关闭原生面板不改变字号或正在编辑的原文。
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard let pointSize = Double(size.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            feedback.stringValue = "字号必须填写 7–32 的数值，原输入字体保留。"
            return
        }
        var preferences = SearchInputFont()
        preferences.family = family.titleOfSelectedItem ?? inputFontConfiguration.family
        preferences.pointSize = pointSize
        do {
            try setInputFont(preferences)
        }
        catch {
            feedback.stringValue = error.localizedDescription
        }
    }
}
