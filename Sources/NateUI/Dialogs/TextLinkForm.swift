import AppKit
import NateCore

@MainActor
final class TextLinkForm: NSStackView, NSTextViewDelegate {
    let modes = NSPopUpButton(frame: .zero, pullsDown: false)
    let prefixes = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))

    /// 业务作用：链接草稿与显示表单共同确认，编辑协议定义不打开目标或触发正文分析。
    /// 参数说明:
    /// - settings: 当前完整链接显示与附加协议定义。
    /// 返回：具有独立原文草稿及容量保护的原生设置页，不改变现有偏好和正文。
    init(settings: TextLinkSettings) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        for (label, mode) in [
            ("关闭链接", TextLinkDisplayMode.disabled),
            ("下划线，悬停前景色", .underlinedForeground),
            ("下划线，悬停背景色", .underlinedBackground),
            ("仅悬停前景色", .foregroundOnHover),
            ("仅悬停背景色", .backgroundOnHover),
        ] {
            modes.addItem(withTitle: label)
            modes.lastItem?.representedObject = mode.rawValue
            if mode == settings.mode {
                modes.selectItem(at: modes.numberOfItems - 1)
            }
        }
        modes.setAccessibilityLabel("正文链接显示方式")
        prefixes.string = settings.additionalPrefixes
        prefixes.isRichText = false
        prefixes.isAutomaticQuoteSubstitutionEnabled = false
        prefixes.isAutomaticDashSubstitutionEnabled = false
        prefixes.isAutomaticTextReplacementEnabled = false
        prefixes.isAutomaticSpellingCorrectionEnabled = false
        prefixes.isAutomaticLinkDetectionEnabled = false
        prefixes.isAutomaticDataDetectionEnabled = false
        prefixes.isContinuousSpellCheckingEnabled = false
        prefixes.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        prefixes.isHorizontallyResizable = false
        prefixes.isVerticallyResizable = true
        prefixes.autoresizingMask = [.width]
        prefixes.textContainer?.widthTracksTextView = true
        prefixes.textContainer?.lineFragmentPadding = 0
        prefixes.textContainerInset = NSSize(width: 6, height: 6)
        prefixes.setAccessibilityLabel("附加链接协议前缀，空格或换行分隔")
        prefixes.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = prefixes
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let hint = NSTextField(
            wrappingLabelWithString:
                "双击打开链接，普通单击选择正文。基本协议保留 http://、https://、ftp://、mailto: 与 file://。"
                + "附加协议用空格或换行分隔，最多 32 项、每项 64 字节，总计 2048 字节；关闭显示仍保留定义。"
        )
        hint.preferredMaxLayoutWidth = 380
        for view in [
            NSTextField(labelWithString: "链接显示"), modes,
            NSTextField(labelWithString: "附加协议"), scroll, hint,
        ] {
            addArrangedSubview(view)
        }
    }

    /// 业务作用：配置草稿只能从已验证设置建立，界面归档不能注入协议或来源。
    /// 参数说明:
    /// - coder: 系统请求恢复的界面归档。
    /// 返回：不从归档恢复此设置页。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：协议编辑即时限制原字节容量，粘贴或组合输入不构造超过配置容量的新草稿。
    /// 参数说明:
    /// - textView: 当前协议草稿编辑器。
    /// - affectedCharRange: 系统提供的待替换 UTF-16 范围。
    /// - replacementString: 系统输入或粘贴的完整替换内容，为空表示仅改变属性。
    /// 返回：范围有效且完整新内容不超过 2048 UTF-8 字节时允许修改，否则保留原草稿。
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        // 协议草稿的委托没有授权其它编辑器，也不能接受系统哨兵或半个 Unicode 标量范围。
        guard textView === prefixes else {
            return false
        }
        let original = textView.string
        let length = original.utf16.count
        guard affectedCharRange.location != NSNotFound, affectedCharRange.location >= 0,
            affectedCharRange.length >= 0, affectedCharRange.location <= length,
            affectedCharRange.length <= length - affectedCharRange.location,
            let range = Range(affectedCharRange, in: original),
            range.lowerBound.samePosition(in: original.unicodeScalars) != nil,
            range.upperBound.samePosition(in: original.unicodeScalars) != nil
        else {
            NSSound.beep()
            return false
        }
        guard let replacementString else {
            return true
        }
        let retained = original.utf8.count - original[range].utf8.count
        guard replacementString.utf8.count <= 2048 - retained else {
            NSSound.beep()
            return false
        }
        return true
    }

    /// 业务作用：只有已结束组合输入且整份协议合法的草稿才能随显示偏好一起应用。
    /// 参数说明: 无。
    /// 返回：完整有效的链接设置；候选未完成或定义非法时保留当前草稿并拒绝应用。
    func settings() throws -> TextLinkSettings {
        guard !prefixes.hasMarkedText(),
            let raw = modes.selectedItem?.representedObject as? String,
            let mode = TextLinkDisplayMode(rawValue: raw)
        else {
            throw NateError.message("请先确认或取消协议输入，并选择链接显示方式。")
        }
        return try TextLinkSettings(mode: mode, additionalPrefixes: prefixes.string)
    }
}
