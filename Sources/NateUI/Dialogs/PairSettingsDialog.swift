import AppKit
import NateCore

@MainActor
public enum PairSettingsDialog {
    /// 业务作用：用户通过双列表单完整编辑配对定义，草稿增删不提前改变正文或偏好。
    /// 参数说明:
    /// - initial: 打开时完整规则。
    /// - warning: 原归档无法读取时保留的说明。
    /// 返回：明确应用且全部定义有效时提供完整设置；取消时为空。
    public static func choose(initial: PairInsertionSettings, warning: String?) -> PairInsertionSettings? {
        let draft = PairSettingsDraft(initial: initial)
        let enabled = NSButton(
            checkboxWithTitle: "对普通直接输入启用括号与引号配对",
            target: nil,
            action: nil
        )
        enabled.state = initial.enabled ? .on : .off
        let skip = NSButton(
            checkboxWithTitle: "输入闭合符时越过光标后的相同闭合符",
            target: nil,
            action: nil
        )
        skip.state = initial.skipExisting ? .on : .off
        let heading = NSStackView(views: [
            NSTextField(labelWithString: "开端 · 单个完整字形"),
            NSTextField(labelWithString: "闭合 · 单个完整字形"),
        ])
        heading.spacing = 16
        for field in heading.arrangedSubviews {
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        let note = NSTextField(
            wrappingLabelWithString:
                "最多 64 项，每端最多 64 个 UTF-8 字节，不能含空白或控制符。相同开端不能重复。普通选择被一对字符替换，光标位于两端之间；词内对称引号及反斜杠转义保留字面输入。覆盖模式、矩形、输入法候选、粘贴与工具原文不自动配对。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        let status = NSTextField(wrappingLabelWithString: warning ?? "")
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 520
        let form = NSStackView(views: [enabled, skip, heading, draft.scroll, draft.buttons, note, status])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.widthAnchor.constraint(equalToConstant: 520).isActive = true
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
        alert.messageText = "括号与引号配对"
        alert.informativeText = "修改只影响后续直接输入；生成字符、光标及原选择属于同一撤销动作。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(
                x: 8,
                y: 8,
                width: 520,
                height: max(420, form.fittingSize.height)
            )
            background.frame = NSRect(
                x: 0,
                y: 0,
                width: 536,
                height: form.frame.height + 16
            )
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            do {
                let pairs = try draft.rows.map {
                    try AutomaticPair(
                        opening: $0.opening.stringValue,
                        closing: $0.closing.stringValue
                    )
                }
                return try PairInsertionSettings(
                    enabled: enabled.state == .on,
                    pairs: pairs,
                    skipExisting: skip.state == .on
                )
            }
            catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class PairRowsView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private struct PairSettingsRow {
    let opening: NSTextField
    let closing: NSTextField
    let remove: NSButton
    let view: NSStackView
}

@MainActor
private final class PairSettingsDraft: NSObject {
    let scroll = NSScrollView()
    let document = PairRowsView()
    let list = NSStackView()
    let buttons = NSStackView()
    let add = NSButton()
    var rows: [PairSettingsRow] = []

    /// 业务作用：编辑草稿独立持有完整行字段，新增、删除及恢复预装均只改变当前表单。
    /// 参数说明:
    /// - initial: 打开时的全部配对定义。
    /// 返回：有界且可滚动的双列表单，不写入任何偏好。
    init(initial: PairInsertionSettings) {
        super.init()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        document.addSubview(list)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        add.title = "添加配对"
        add.target = self
        add.action = #selector(addRow(_:))
        let restore = NSButton(
            title: "恢复预装配对",
            target: self,
            action: #selector(restoreRows(_:))
        )
        buttons.addArrangedSubview(add)
        buttons.addArrangedSubview(restore)
        buttons.spacing = 10
        for pair in initial.pairs {
            append(opening: pair.opening, closing: pair.closing)
        }
        updateGeometry()
    }

    /// 业务作用：添加一个尚未通过验证的草稿行，数量达到容量后保持现有定义。
    /// 参数说明: 无。
    /// 返回：新增空字段且滚动到该行，完整规则仍须点击应用后验证。
    @objc private func addRow(_ sender: Any?) {
        guard rows.count < 64 else {
            return
        }
        append(opening: "", closing: "")
        rows.last?.view.scrollToVisible(rows.last?.view.bounds ?? .zero)
    }

    /// 业务作用：删除用户明确点击的草稿行，其它行的未确认原文继续保留。
    /// 参数说明:
    /// - sender: 标识当前行的删除按钮。
    /// 返回：只移除对应的草稿行，不改变当前生效配对。
    @objc private func removeRow(_ sender: NSButton) {
        guard
            let index = rows.firstIndex(where: {
                $0.remove === sender
            })
        else {
            return
        }
        let row = rows.remove(at: index)
        list.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        updateGeometry()
    }

    /// 业务作用：明确恢复全部预装配对到当前草稿，启用与越过开关保留用户本次选择。
    /// 参数说明: 无。
    /// 返回：当前自定义行被完整预装定义替代，取消表单仍不保存。
    @objc private func restoreRows(_ sender: Any?) {
        for row in rows {
            list.removeArrangedSubview(row.view)
            row.view.removeFromSuperview()
        }
        rows = []
        for pair in PairInsertionSettings().pairs {
            append(opening: pair.opening, closing: pair.closing)
        }
        updateGeometry()
    }

    /// 业务作用：建立一行真实可编辑的两端字段，行身份通过删除按钮绑定而非可能变化的序号。
    /// 参数说明:
    /// - opening: 当前草稿开端原文。
    /// - closing: 当前草稿闭合原文。
    /// 返回：保留原 Unicode 的完整行并更新滚动容量。
    private func append(opening: String, closing: String) {
        let left = NSTextField(string: opening), right = NSTextField(string: closing)
        left.setAccessibilityLabel("配对开端")
        right.setAccessibilityLabel("配对闭合")
        let remove = NSButton(
            title: "删除",
            target: self,
            action: #selector(removeRow(_:))
        )
        let row = NSStackView(views: [left, right, remove])
        row.spacing = 16
        for field in [left, right] {
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        remove.widthAnchor.constraint(equalToConstant: 60).isActive = true
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        rows.append(
            PairSettingsRow(
                opening: left,
                closing: right,
                remove: remove,
                view: row
            )
        )
        list.addArrangedSubview(row)
        updateGeometry()
    }

    /// 业务作用：固定双列宽度并只滚动定义列表，表单中的开关和验证说明始终可见。
    /// 参数说明: 无。
    /// 返回：最多六十四行的完整滚动范围，新增按钮随真实容量启用或关闭。
    private func updateGeometry() {
        let height = CGFloat(rows.count * 32)
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: 500,
            height: max(180, height)
        )
        list.frame = NSRect(
            x: 0,
            y: 0,
            width: 500,
            height: height
        )
        add.isEnabled = rows.count < 64
    }
}
