import AppKit
import NateCore

@MainActor
public enum DateTimeDialog {
    /// 业务作用：独立草稿预览当前日期时间格式，只有明确应用才交付完整偏好。
    /// 参数说明:
    /// - initial: 打开时固定的完整格式及短长次序。
    /// - warning: 原归档损坏或未知格式的说明。
    /// 返回：合法且有完整输出的配置，取消为空；错误保留草稿并允许继续修改。
    public static func choose(initial: DateTimeSettings, warning: String?) -> DateTimeSettings? {
        let form = DateTimeForm(initial: initial, warning: warning)
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form.stack)
        let alert = NSAlert()
        alert.messageText = "日期时间格式"
        alert.informativeText = "编辑菜单分别提供短日期时间、长日期时间和自定义格式。插入时固定同一时刻，预览不会修改正文。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.stack.frame = NSRect(x: 8, y: 8, width: 480, height: max(300, form.stack.fittingSize.height))
            background.setFrameSize(NSSize(width: 496, height: form.stack.frame.height + 16))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            alert.window.makeFirstResponder(nil)
            do {
                let value = try form.settings()
                _ = try value.formatted(date: form.date, mode: .custom)
                return value
            }
            catch {
                form.status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class DateTimeForm: NSObject, NSTextFieldDelegate {
    let format: NSTextField
    let order: NSButton
    let preview = NSTextField(wrappingLabelWithString: "")
    let status: NSTextField
    let stack = NSStackView()
    let date = Date()

    /// 业务作用：表单固定一个预览时刻，字段编辑只重新计算草稿而不写偏好。
    /// 参数说明:
    /// - initial: 完整原格式与短长次序。
    /// - warning: 原归档无法读取时持续显示的说明。
    /// 返回：可编辑原格式、次序开关和只读完整预览。
    init(initial: DateTimeSettings, warning: String?) {
        format = NSTextField(string: initial.format)
        order = NSButton(checkboxWithTitle: "短格式和长格式先日期后时间", target: nil, action: nil)
        status = NSTextField(wrappingLabelWithString: warning ?? "")
        super.init()
        format.setAccessibilityLabel("日期时间自定义格式")
        format.delegate = self
        order.state = initial.dateFirst ? .on : .off
        preview.setAccessibilityLabel("日期时间预览")
        preview.isSelectable = true
        preview.preferredMaxLayoutWidth = 480
        let note = NSTextField(
            wrappingLabelWithString:
                "字段：yyyy 年、MM 月、dd 日、ddd/dddd 星期、MMM/MMMM 月名、HH 二十四小时、hh 十二小时、mm 分、ss 秒、t/tt 上午下午、g 纪元。单引号包围字面文字，两个单引号输出一个单引号。短长格式使用 macOS 地区与日历。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 480
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in [
            NSTextField(labelWithString: "自定义格式（最多 256 个 UTF-16 单元）"), format,
            order, NSTextField(labelWithString: "自定义预览"), preview, note, status,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        format.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updatePreview()
    }

    /// 业务作用：以当前独立草稿建立完整设置，不对格式做裁剪或转义替换。
    /// 参数说明: 无。
    /// 返回：全部合法时返回完整配置，否则说明原草稿的拒绝原因。
    func settings() throws -> DateTimeSettings {
        try DateTimeSettings(format: format.stringValue, dateFirst: order.state == .on)
    }

    /// 业务作用：系统文本编辑通知只更新预览，错误不写入偏好或正文。
    /// 参数说明:
    /// - notification: 自定义格式文本变更通知。
    /// 返回：预览反映同一固定时刻与当前格式。
    func controlTextDidChange(_ notification: Notification) {
        updatePreview()
    }

    /// 业务作用：只有完整有效的格式才展示可插入文字，失败明确呈现原因。
    /// 参数说明: 无。
    /// 返回：更新只读预览，不覆盖原归档警告。
    private func updatePreview() {
        do {
            preview.stringValue = try settings().formatted(date: date, mode: .custom)
        }
        catch {
            preview.stringValue = error.localizedDescription
        }
    }
}
