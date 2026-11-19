import AppKit
import NateCore

@MainActor
public final class CharacterConverterPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    public var onInsert: ((String) -> Bool)?
    public var onClose: (() -> Void)?
    public let status = NSTextField(wrappingLabelWithString: "")
    public private(set) var fields: [CharacterConversionField: NSTextField] = [:]
    public private(set) var model: CharacterConversion?
    public var insertionEnabled = false {
        didSet {
            refreshButtons()
        }
    }
    private var copies: [CharacterConversionField: NSButton] = [:]
    private var inserts: [CharacterConversionField: NSButton] = [:]

    /// 业务作用：任一字符或进制字段均可作为完整输入，其它字段从同一 UInt32 数值同步生成。
    /// 参数说明: 无。
    /// 返回：独立可复制与显式插入的转换面板，不把 Unicode 字符当作单个原始字节。
    public init() {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 760,
                height: 350
            ),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "字符与进制转换"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let explanation = NSTextField(
            wrappingLabelWithString:
                "字符按单个 Unicode 标量解释，数值范围为 UInt32（0–4294967295）。数值字段不含正负号、空白或 0x 等前缀；无效 Unicode 数值仍可在各进制间转换。HEX 原字节编解码使用工具菜单中的独立命令。"
        )
        explanation.textColor = .secondaryLabelColor
        var rows: [NSView] = [explanation]
        for (index, kind) in CharacterConversionField.allCases.enumerated() {
            let label = NSTextField(labelWithString: kind.title)
            let field = NSTextField(string: "")
            field.tag = index
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.setAccessibilityLabel(kind.title + "完整输入")
            let copy = NSButton(
                title: "复制",
                target: self,
                action: #selector(copyField(_:))
            )
            let insert = NSButton(
                title: "插入",
                target: self,
                action: #selector(insertField(_:))
            )
            copy.tag = index
            insert.tag = index
            fields[kind] = field
            copies[kind] = copy
            inserts[kind] = insert
            let row = NSStackView(views: [label, field, copy, insert])
            row.spacing = 8
            label.widthAnchor.constraint(equalToConstant: 105).isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
            rows.append(row)
        }
        let target = NSTextField(
            wrappingLabelWithString: "“插入”使用打开面板时的正文选区，并形成正常撤销与输入宏动作；正文、选择或权限改变后请重新打开面板。"
        )
        target.textColor = .secondaryLabelColor
        rows.append(contentsOf: [target, status])
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSBox()
        root.boxType = .custom
        root.title = ""
        root.borderWidth = 0
        root.contentViewMargins = .zero
        root.fillColor = .windowBackgroundColor
        panel.contentView = root
        root.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ]
        for row in rows {
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        apply("A", field: .character)
        panel.center()
    }

    /// 业务作用：转换面板不恢复归档中无法证明来源的旧正文插入目标。
    /// 参数说明:
    /// - coder: 原生界面归档。
    /// 返回：拒绝归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：每次实际输入按所在字段完整解析，不保留上一个有效值的复制或插入资格。
    /// 参数说明:
    /// - notification: 原生字段变化通知。
    /// 返回：有效时同步其余字段；非法草稿保留原输入并关闭所有输出动作。
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            CharacterConversionField.allCases.indices.contains(field.tag)
        else {
            return
        }
        apply(field.stringValue, field: CharacterConversionField.allCases[field.tag])
    }

    /// 业务作用：明确字段作为唯一输入，数值和 Unicode 有效性分别保留。
    /// 参数说明:
    /// - input: 当前完整原输入。
    /// - field: 用户明确编辑的输入类型。
    /// 返回：所有输出来自同一合法值，非法时不会复制或插入过期结果。
    public func apply(_ input: String, field: CharacterConversionField) {
        fields[field]?.stringValue = input
        do {
            let value = try CharacterConversion(input: input, field: field)
            model = value
            for kind in CharacterConversionField.allCases where kind != field {
                fields[kind]?.stringValue = value.representation(for: kind) ?? ""
            }
            let code = String(value.value, radix: 16, uppercase: true)
            status.stringValue =
                value.character == nil
                ? "数值 \(value.value) 不属于 Unicode 标量；字符复制和插入不可用。"
                : "Unicode U+\(code) · 十进制 \(value.value) · 字符插入使用该标量的 UTF-8 文本。"
        }
        catch {
            model = nil
            for kind in CharacterConversionField.allCases where kind != field {
                fields[kind]?.stringValue = ""
            }
            status.stringValue = error.localizedDescription
        }
        refreshButtons()
    }

    /// 业务作用：关闭后解除原正文插入回调持有权，不修改输入来源或工作区。
    /// 参数说明:
    /// - notification: 原生关闭通知。
    /// 返回：由控制器释放当前面板。
    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// 业务作用：完整有效字段与原正文目标分别决定复制和插入资格。
    /// 参数说明: 无。
    /// 返回：无效 Unicode 字符或非法输入无法沿旧按钮产生输出。
    private func refreshButtons() {
        for kind in CharacterConversionField.allCases {
            let valid = model?.representation(for: kind) != nil
            copies[kind]?.isEnabled = valid
            inserts[kind]?.isEnabled = valid && insertionEnabled
        }
    }

    /// 业务作用：显式复制当前合法值的完整字段，不读取界面中的旧草稿或截断显示。
    /// 参数说明:
    /// - sender: 用户明确选择的字段复制按钮。
    /// 返回：仅发布实际有效字段，不解释为原始八位字节。
    @objc private func copyField(_ sender: NSButton) {
        guard CharacterConversionField.allCases.indices.contains(sender.tag),
            let value = model?.representation(for: CharacterConversionField.allCases[sender.tag])
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status.stringValue = "已复制完整字段。"
    }

    /// 业务作用：插入由业务控制器复验原正文证据，数值字段与字符字段均使用明确完整文本。
    /// 参数说明:
    /// - sender: 用户明确选择的字段插入按钮。
    /// 返回：实际成功后才提示完成；失败保持字段和原正文。
    @objc private func insertField(_ sender: NSButton) {
        guard insertionEnabled, CharacterConversionField.allCases.indices.contains(sender.tag),
            let value = model?.representation(for: CharacterConversionField.allCases[sender.tag])
        else {
            return
        }
        if onInsert?(value) == true {
            status.stringValue = "已插入完整字段，可撤销。"
        }
    }
}
