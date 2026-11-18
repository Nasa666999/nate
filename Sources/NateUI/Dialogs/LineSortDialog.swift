import AppKit
import NateCore

@MainActor
public enum LineSortDialog {
    /// 业务作用：在执行前明确键解释、方向与 macOS 语言地区，不把当前区域默认当成跨平台相同规则。
    /// 参数说明:
    /// - scope: 当前真实选择的范围和列语义。
    /// - initial: 上次明确确认的选项。
    /// 返回：用户确认的完整配置；取消时不启动排序或改写正文。
    public static func choose(scope: String, initial: LineSortOptions) -> LineSortOptions? {
        let alert = NSAlert()
        alert.messageText = "行排序"
        alert.informativeText =
            scope
            + "\n相同键保留原行顺序。字符序和行长度使用 UTF-16 码元；小数只解释所选分隔符的数字前缀。"
        alert.addButton(withTitle: "排序整行")
        alert.addButton(withTitle: "取消")
        let kind = NSPopUpButton()
        let choices: [(LineSortKind, String)] = [
            (.lexicographic, "字符序"), (.ignoringCase, "忽略大小写"), (.locale, "macOS 语言地区规则"),
            (.integer, "带符号整数片段"), (.decimalComma, "逗号小数"), (.decimalDot, "点号小数"),
            (.length, "行长度"), (.reverse, "反转行序"), (.random, "随机行序"),
        ]
        kind.addItems(withTitles: choices.map(\.1))
        kind.selectItem(
            at: choices.firstIndex(where: {
                $0.0 == initial.kind
            }) ?? 0
        )
        let direction = NSPopUpButton()
        direction.addItems(withTitles: ["升序", "降序"])
        direction.selectItem(at: initial.descending ? 1 : 0)
        let locale = NSComboBox()
        locale.addItems(withObjectValues: Locale.availableIdentifiers.sorted())
        locale.stringValue = initial.localeIdentifier
        locale.completes = true
        let fields: [(String, NSView)] = [
            ("规则", kind), ("方向", direction), ("语言地区", locale),
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (label, control) in fields {
            let title = NSTextField(labelWithString: label)
            title.widthAnchor.constraint(equalToConstant: 82).isActive = true
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let row = NSStackView(views: [title, control])
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        let note = NSTextField(
            wrappingLabelWithString:
                "语言地区仅用于区域规则；反转与随机忽略方向。普通无选区排序全文，矩形只用所选列作键并移动整行。"
        )
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 394).isActive = true
        stack.addArrangedSubview(note)
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: 394, height: stack.fittingSize.height)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return LineSortOptions(
            kind: choices[kind.indexOfSelectedItem].0,
            descending: direction.indexOfSelectedItem == 1,
            localeIdentifier: locale.stringValue
        )
    }
}
