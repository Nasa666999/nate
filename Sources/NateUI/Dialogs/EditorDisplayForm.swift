import AppKit
import NateCore

@MainActor
public final class EditorDisplayForm: NSStackView {
    let fonts = NSPopUpButton(frame: .zero, pullsDown: false)
    let size = NSTextField()
    let appearances = NSPopUpButton(frame: .zero, pullsDown: false)
    let wrapping = NSButton(checkboxWithTitle: "自动换行", target: nil, action: nil)
    let symbols = NSButton(checkboxWithTitle: "显示空白与控制符号", target: nil, action: nil)

    /// 业务作用：原生表单保留完整显示偏好，已配置但当前不可用的字体不会因打开设置被丢弃。
    /// 参数说明:
    /// - settings: 当前已验证配置及活动视图的显示值。
    /// 返回：可独立读取和取消的设置草稿，不发布全局外观或修改正文。
    public init(settings: EditorDisplaySettings) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        fonts.addItem(withTitle: "系统等宽字体")
        var known: Set<String> = []
        for family in NSFontManager.shared.availableFontFamilies.sorted() {
            guard
                let font = NSFontManager.shared.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: CGFloat(settings.fontSize)
                ), known.insert(font.fontName).inserted
            else {
                continue
            }
            fonts.addItem(withTitle: font.displayName ?? family)
            fonts.lastItem?.representedObject = font.fontName
        }
        if let configured = settings.fontName {
            if let item = fonts.itemArray.first(where: {
                $0.representedObject as? String == configured
            }) {
                fonts.select(item)
            }
            else {
                let label =
                    NSFont(name: configured, size: CGFloat(settings.fontSize))?.displayName
                    ?? "当前不可用：" + configured
                fonts.addItem(withTitle: label)
                fonts.lastItem?.representedObject = configured
                fonts.selectItem(at: fonts.numberOfItems - 1)
            }
        }
        size.stringValue = String(settings.fontSize)
        for (label, choice) in [("跟随系统", EditorAppearance.system), ("浅色", .light), ("深色", .dark)] {
            appearances.addItem(withTitle: label)
            appearances.lastItem?.representedObject = choice.rawValue
            if choice == settings.appearance {
                appearances.selectItem(at: appearances.numberOfItems - 1)
            }
        }
        wrapping.state = settings.wrapLines ? .on : .off
        symbols.state = settings.showSymbols ? .on : .off
        fonts.setAccessibilityLabel("正文字体")
        size.setAccessibilityLabel("正文字号")
        appearances.setAccessibilityLabel("外观主题")
        for view in [
            NSTextField(labelWithString: "正文字体"), fonts,
            NSTextField(labelWithString: "字号（7–72，可用小数）"), size,
            NSTextField(labelWithString: "外观主题"), appearances, wrapping, symbols,
        ] {
            addArrangedSubview(view)
        }
        setFrameSize(NSSize(width: 420, height: 260))
        fonts.widthAnchor.constraint(equalToConstant: 400).isActive = true
        size.widthAnchor.constraint(equalToConstant: 140).isActive = true
    }

    /// 业务作用：设置表单只允许从已验证模型建立，不通过界面归档注入其它状态。
    /// 参数说明:
    /// - coder: 系统请求恢复的界面归档。
    /// 返回：拒绝从归档构造此设置草稿。
    public required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：在任何偏好或视图发布前复验整个草稿，输入错误可原地更正并重新应用。
    /// 参数说明: 无。
    /// 返回：字号、主题和字体身份全部合法时返回完整配置，否则拒绝且保留草稿。
    public func settings() throws -> EditorDisplaySettings {
        guard size.stringValue.utf8.count <= 32,
            let pointSize = Double(size.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            let choice = appearances.selectedItem?.representedObject as? String,
            let appearance = EditorAppearance(rawValue: choice), fonts.indexOfSelectedItem >= 0
        else {
            throw NateError.message("请填写有效字号并选择外观主题与字体。")
        }
        return try EditorDisplaySettings(
            fontName: fonts.selectedItem?.representedObject as? String,
            fontSize: pointSize,
            appearance: appearance,
            wrapLines: wrapping.state == .on,
            showSymbols: symbols.state == .on
        )
    }
}
