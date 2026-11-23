import AppKit
import NateCore

@MainActor
final class ThemeStyleFields: NSView {
    let foreground = NSColorWell()
    let background = NSColorWell()
    let inheritForeground = NSButton(checkboxWithTitle: "继承", target: nil, action: nil)
    let inheritBackground = NSButton(checkboxWithTitle: "继承", target: nil, action: nil)
    let fontName = NSTextField(string: "")
    let fontSize = NSTextField(string: "")
    let inheritDecoration = NSButton(checkboxWithTitle: "继承装饰", target: nil, action: nil)
    let bold = NSButton(checkboxWithTitle: "粗体", target: nil, action: nil)
    let italic = NSButton(checkboxWithTitle: "斜体", target: nil, action: nil)
    let underline = NSButton(checkboxWithTitle: "下划线", target: nil, action: nil)
    let foregroundLabel = NSTextField(labelWithString: "前景色")
    private var extraRows: [NSView] = []
    private var colorOnly = false
    private var editable = true

    /// 业务作用：主题属性编辑显式区分继承和完整覆盖，关闭装饰不是缺省值。
    /// 参数说明: 无。
    /// 返回：只维护草稿控件的颜色、字体与装饰面板，不写偏好或正文。
    init() {
        super.init(frame: .zero)
        foreground.identifier = NSUserInterfaceItemIdentifier("themeForeground")
        background.identifier = NSUserInterfaceItemIdentifier("themeBackground")
        fontName.identifier = NSUserInterfaceItemIdentifier("themeFontName")
        fontSize.identifier = NSUserInterfaceItemIdentifier("themeFontSize")
        fontName.placeholderString = "留空继承，支持字体名称"
        fontSize.placeholderString = "继承"
        fontName.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontSize.widthAnchor.constraint(equalToConstant: 80).isActive = true
        for well in [foreground, background] {
            well.widthAnchor.constraint(equalToConstant: 72).isActive = true
            well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let first = row(label: foregroundLabel, controls: [foreground, inheritForeground])
        extraRows = [
            row(label: NSTextField(labelWithString: "背景色"), controls: [background, inheritBackground]),
            row(label: NSTextField(labelWithString: "字体"), controls: [fontName]),
            row(label: NSTextField(labelWithString: "字号"), controls: [fontSize]),
            row(
                label: NSTextField(labelWithString: "字体装饰"),
                controls: [inheritDecoration, bold, italic, underline]
            ),
        ]
        let stack = NSStackView(views: [first] + extraRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for checkbox in [inheritForeground, inheritBackground, inheritDecoration] {
            checkbox.target = self
            checkbox.action = #selector(inheritanceChanged(_:))
        }
        load(EditorThemeStyle(), colorOnly: false, editable: false)
    }

    /// 业务作用：主题表单采用程序化布局，不从归档恢复未验证的控件状态。
    /// 参数说明:
    /// - coder: 系统归档来源。
    /// 返回：不支持此初始化路径。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：一项样式切换只安装已校验的草稿值，未明确覆盖的字段保持继承显示。
    /// 参数说明:
    /// - style: 当前完整合法的单项样式。
    /// - colorOnly: 整体界面角色只编辑一种颜色。
    /// - editable: 当前是否有明确可编辑主题和样式目标。
    /// 返回：所有控件同步到同一项草稿，隐藏字段不参与当前读取。
    func load(_ style: EditorThemeStyle, colorOnly: Bool, editable: Bool) {
        self.colorOnly = colorOnly
        self.editable = editable
        foregroundLabel.stringValue = colorOnly ? "颜色" : "前景色"
        inheritForeground.state = style.foreground == nil ? .on : .off
        inheritBackground.state = style.background == nil ? .on : .off
        foreground.color = style.foreground.flatMap(Self.color) ?? .textColor
        background.color = style.background.flatMap(Self.color) ?? .textBackgroundColor
        fontName.stringValue = style.fontName ?? ""
        fontSize.stringValue = style.fontSize.map(String.init) ?? ""
        inheritDecoration.state = style.fontStyle == nil ? .on : .off
        bold.state = (style.fontStyle ?? 0) & 1 != 0 ? .on : .off
        italic.state = (style.fontStyle ?? 0) & 2 != 0 ? .on : .off
        underline.state = (style.fontStyle ?? 0) & 4 != 0 ? .on : .off
        for row in extraRows {
            row.isHidden = colorOnly
        }
        updateEnabled()
    }

    /// 业务作用：应用草稿前校验实际控件值，非法颜色或字号不会替换此前有效样式。
    /// 参数说明: 无。
    /// 返回：完整单项覆盖，继承字段为空；非法输入抛错并保留控件中的原草稿。
    func value() throws -> EditorThemeStyle {
        let foreground = try inheritForeground.state == .on ? nil : Self.hex(self.foreground.color)
        if colorOnly {
            return try EditorThemeStyle(foreground: foreground)
        }
        let background = try inheritBackground.state == .on ? nil : Self.hex(self.background.color)
        let sizeText = fontSize.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let size: Int?
        if sizeText.isEmpty {
            size = nil
        }
        else {
            guard sizeText.utf8.count <= 3, let parsed = Int(sizeText) else {
                throw NateError.message("主题字号须为 1 至 512，留空表示继承。")
            }
            size = parsed
        }
        let decoration =
            inheritDecoration.state == .on
            ? nil
            : (bold.state == .on ? 1 : 0) | (italic.state == .on ? 2 : 0) | (underline.state == .on ? 4 : 0)
        return try EditorThemeStyle(
            foreground: foreground,
            background: background,
            fontName: fontName.stringValue.isEmpty ? nil : fontName.stringValue,
            fontSize: size,
            fontStyle: decoration
        )
    }

    /// 业务作用：继承开关只改变草稿控件的编辑资格，不立即发布颜色或字体。
    /// 参数说明:
    /// - sender: 当前明确切换的继承控件。
    /// 返回：依赖当前继承状态的输入控件同步启用或停用。
    @objc private func inheritanceChanged(_ sender: NSButton) {
        updateEnabled()
    }

    /// 业务作用：系统继承与明确主题目标决定属性控件资格，禁止向不存在的样式写入草稿。
    /// 参数说明: 无。
    /// 返回：颜色和装饰控件的启用状态与目标保持一致。
    private func updateEnabled() {
        for control in [inheritForeground, inheritBackground, inheritDecoration, bold, italic, underline] {
            control.isEnabled = editable
        }
        foreground.isEnabled = editable && inheritForeground.state != .on
        background.isEnabled = editable && inheritBackground.state != .on
        fontName.isEnabled = editable
        fontSize.isEnabled = editable
        for control in [bold, italic, underline] {
            control.isEnabled = editable && inheritDecoration.state != .on
        }
    }

    /// 业务作用：单行属性保持可读标签和原生键盘控件顺序，不依赖固定屏幕坐标。
    /// 参数说明:
    /// - label: 当前属性的用户可见标签。
    /// - controls: 当前属性的原生输入控件。
    /// 返回：与其它属性对齐的独立布局行。
    private func row(label: NSTextField, controls: [NSView]) -> NSView {
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    /// 业务作用：合法主题颜色仅转换为固定 sRGB，继承值由调用方提供来源系统色。
    /// 参数说明:
    /// - value: 已校验的井号六位 RGB。
    /// 返回：固定原生颜色，非法值为空。
    private static func color(_ value: String) -> NSColor? {
        guard value.utf8.count == 7, let raw = UInt32(value.dropFirst(), radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((raw >> 16) & 255) / 255,
            green: CGFloat((raw >> 8) & 255) / 255,
            blue: CGFloat(raw & 255) / 255,
            alpha: 1
        )
    }

    /// 业务作用：颜色面板的实际选择在保存前固定为不透明 RGB，不能隐式舍弃透明度或模式色。
    /// 参数说明:
    /// - color: 当前原生颜色控件的完整选择。
    /// 返回：完整 #RRGGBB；不能表示为不透明 sRGB 时拒绝。
    private static func hex(_ color: NSColor) throws -> String {
        guard let value = color.usingColorSpace(.sRGB), value.alphaComponent >= 0.99999 else {
            throw NateError.message("主题颜色须为不透明 RGB，请重新选择颜色。")
        }
        let channels = [value.redComponent, value.greenComponent, value.blueComponent].map {
            Int((max(0, min(1, $0)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}
