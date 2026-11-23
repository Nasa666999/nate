import AppKit
import NateCore

@MainActor
public final class EditorDisplayForm: NSStackView {
    let fonts = NSPopUpButton(frame: .zero, pullsDown: false)
    let size = NSTextField()
    let appearances = NSPopUpButton(frame: .zero, pullsDown: false)
    let wrapping = NSButton(checkboxWithTitle: "自动换行", target: nil, action: nil)
    let symbols = NSButton(checkboxWithTitle: "显示空白与控制符号", target: nil, action: nil)
    let indentation = NSButton(checkboxWithTitle: "显示缩进参考线", target: nil, action: nil)
    let modifications = NSButton(checkboxWithTitle: "显示修改历史边栏与正文指示", target: nil, action: nil)
    let longLine = NSButton(checkboxWithTitle: "长行参考线", target: nil, action: nil)
    let column = NSTextField(string: "80")
    let pages = NSTabView()
    let sections = NSSegmentedControl(
        labels: ["字体与显示", "链接"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let linkForm: TextLinkForm
    private let originalColumn: Int

    /// 业务作用：原生表单保留完整显示偏好，已配置但当前不可用的字体不会因打开设置被丢弃。
    /// 参数说明:
    /// - settings: 当前已验证配置及活动视图的显示值。
    /// 返回：可独立读取和取消的设置草稿，不发布全局外观或修改正文。
    public init(settings: EditorDisplaySettings) {
        originalColumn = settings.longLineColumn
        linkForm = TextLinkForm(settings: settings.textLinks)
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
        indentation.state = settings.showIndentGuides ? .on : .off
        modifications.state = settings.showModificationHistory ? .on : .off
        longLine.state = settings.showLongLineGuide ? .on : .off
        column.stringValue = String(settings.longLineColumn)
        column.isEnabled = longLine.state == .on
        column.widthAnchor.constraint(equalToConstant: 80).isActive = true
        column.setAccessibilityLabel("长行参考列，1 至 4096")
        longLine.target = self
        longLine.action = #selector(referenceChanged(_:))
        let reference = NSStackView(views: [longLine, column, NSTextField(labelWithString: "列")])
        reference.spacing = 8
        fonts.setAccessibilityLabel("正文字体")
        size.setAccessibilityLabel("正文字号")
        appearances.setAccessibilityLabel("外观主题")
        let displayFields = NSStackView()
        displayFields.orientation = .vertical
        displayFields.alignment = .leading
        displayFields.spacing = 8
        for view in [
            NSTextField(labelWithString: "正文字体"), fonts,
            NSTextField(labelWithString: "字号（7–72，可用小数）"), size,
            NSTextField(labelWithString: "外观主题"), appearances, wrapping, symbols, indentation, reference,
            modifications,
        ] {
            displayFields.addArrangedSubview(view)
        }
        fonts.widthAnchor.constraint(equalToConstant: 400).isActive = true
        size.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let display = NSTabViewItem(identifier: "display")
        display.label = "字体与显示"
        display.view = displayFields
        let links = NSTabViewItem(identifier: "links")
        links.label = "链接"
        links.view = linkForm
        pages.addTabViewItem(display)
        pages.addTabViewItem(links)
        pages.tabViewType = .noTabsNoBorder
        pages.selectTabViewItem(display)
        sections.selectedSegment = 0
        sections.target = self
        sections.action = #selector(changeSection(_:))
        sections.setAccessibilityLabel("设置分类")
        let height = max(260, max(displayFields.fittingSize.height, linkForm.fittingSize.height)) + 24
        pages.widthAnchor.constraint(equalToConstant: 420).isActive = true
        pages.heightAnchor.constraint(equalToConstant: height).isActive = true
        addArrangedSubview(sections)
        addArrangedSubview(pages)
        setFrameSize(NSSize(width: 420, height: height))
    }

    /// 业务作用：可见分类按钮切换独立设置草稿，切换期间不提交偏好或丢弃另一页输入。
    /// 参数说明:
    /// - sender: 本表单实际分类按钮。
    /// 返回：有效按钮及分类显示对应页面，外部控件或非法分类保留当前页面。
    @objc func changeSection(_ sender: NSSegmentedControl) {
        guard sender === sections, (0..<pages.numberOfTabViewItems).contains(sender.selectedSegment) else {
            return
        }
        pages.selectTabViewItem(at: sender.selectedSegment)
    }

    /// 业务作用：长行参考列只在用户明确开启时参与设置，关闭不立即保存草稿或改变正文。
    /// 参数说明:
    /// - sender: 当前长行参考线开关。
    /// 返回：列输入的编辑资格与当前草稿开关一致。
    @objc private func referenceChanged(_ sender: NSButton) {
        column.isEnabled = sender.state == .on
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
    /// 返回：字号、主题、字体身份及完整链接定义全部合法时返回整份配置，否则拒绝且保留草稿。
    public func settings() throws -> EditorDisplaySettings {
        let referenceColumn: Int
        let raw = column.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.utf8.count <= 4, let value = Int(raw), (1...4096).contains(value) {
            referenceColumn = value
        }
        else if longLine.state == .on {
            throw NateError.message("长行参考列须为 1 至 4096 的整数。")
        }
        else {
            referenceColumn = originalColumn
        }
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
            showSymbols: symbols.state == .on,
            showIndentGuides: indentation.state == .on,
            longLineColumn: referenceColumn,
            showLongLineGuide: longLine.state == .on,
            showModificationHistory: modifications.state == .on,
            textLinks: linkForm.settings()
        )
    }
}
