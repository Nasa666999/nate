import AppKit
import NateCore

@MainActor
public enum ColumnEditorDialog {
    /// 业务作用：以明确字段收集固定文本或完整数字格式，不要求用户编写逗号参数串。
    /// 参数说明:
    /// - scope: 本次实际目标范围说明。
    /// - initial: 上次明确选择的配置，为空时采用默认数字序列。
    /// 返回：确认且完整有效的列值配置；取消时为空，正文从不由对话框修改。
    public static func choose(scope: String, initial: ColumnInsertionValue? = nil) -> ColumnInsertionValue? {
        ColumnEditorForm(scope: scope, initial: initial).run()
    }
}

@MainActor
private final class ColumnEditorForm: NSObject {
    private let alert = NSAlert()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let text = SearchInputBox(frame: .zero)
    private let start = NSTextField(string: "1")
    private let step = NSTextField(string: "1")
    private let radix = NSPopUpButton(frame: .zero, pullsDown: false)
    private let repetitions = NSTextField(string: "1")
    private let padding = NSPopUpButton(frame: .zero, pullsDown: false)
    private let width = NSTextField(string: "0")
    private let uppercase = NSButton(checkboxWithTitle: "十六进制字母大写", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var textRow: NSStackView?

    /// 业务作用：把范围和数字含义同时展示，固定文本保留完整原文而非单行摘要。
    /// 参数说明:
    /// - scope: 当前已捕获的文档范围说明。
    /// - initial: 上次确认的完整值配置。
    /// 返回：尚未取得正文提交权的原生表单。
    init(scope: String, initial: ColumnInsertionValue?) {
        super.init()
        mode.addItems(withTitles: ["数字序列", "固定文字"])
        radix.addItems(withTitles: ["二进制", "八进制", "十进制", "十六进制"])
        radix.selectItem(at: 2)
        padding.addItems(withTitles: ["无填充", "前导零", "前导空格"])
        uppercase.state = .on
        text.placeholderString = "完整固定文字，可包含换行、NUL 与 Unicode"
        text.setHistoryVisible(false)
        text.onFeedback = {
            [weak self] message in self?.feedback.stringValue = message
        }
        if let initial {
            switch initial {
            case .text(let value):
                mode.selectItem(at: 1)
                text.stringValue = value
            case .numbers(let value):
                let base = [2, 8, 10, 16].contains(value.radix) ? value.radix : 10
                radix.selectItem(at: [2, 8, 10, 16].firstIndex(of: base) ?? 2)
                start.stringValue = String(value.start, radix: base, uppercase: value.uppercase)
                step.stringValue = String(value.step, radix: base, uppercase: value.uppercase)
                repetitions.stringValue = String(value.repetitions)
                padding.selectItem(at: ColumnNumberPadding.allCases.firstIndex(of: value.padding) ?? 0)
                width.stringValue = String(value.minimumWidth)
                uppercase.state = value.uppercase ? .on : .off
                if (try? value.render(count: 0)) == nil {
                    feedback.stringValue = "上次数字格式无效，请校正参数后确认。"
                }
            }
        }
        let fixedTextRow = row("固定文字", text)
        textRow = fixedTextRow
        let controls = NSStackView(views: [
            row("插入方式", mode),
            fixedTextRow,
            row("进制", radix),
            row("起始值", start),
            row("步长", step),
            row("每值重复次数", repetitions),
            row("前导填充", padding),
            row("最小总宽度", width),
            uppercase,
            feedback,
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.frame = NSRect(x: 0, y: 0, width: 590, height: 340)
        feedback.textColor = .systemRed
        feedback.maximumNumberOfLines = 3
        feedback.preferredMaxLayoutWidth = 590
        alert.messageText = "列编辑器"
        alert.informativeText =
            scope + "\n数字按文档顺序生成。起始值和步长按所选进制填写，不加进制前缀；重复次数与最小宽度使用十进制。宽度 0 自动对齐；符号计入总宽度，补零放在负号之后。"
        alert.accessoryView = controls
        alert.addButton(withTitle: "插入所选内容")
        alert.addButton(withTitle: "取消")
        mode.target = self
        mode.action = #selector(updateAvailability)
        padding.target = self
        padding.action = #selector(updateAvailability)
        radix.target = self
        radix.action = #selector(updateAvailability)
        updateAvailability()
    }

    /// 业务作用：表单行保留清楚的业务标签，宽输入不会把整个弹窗撑出屏幕。
    /// 参数说明:
    /// - label: 原生控件对应的业务含义。
    /// - control: 需要展示的输入控件。
    /// 返回：宽度固定且随字体自然布局的一行。
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        control.widthAnchor.constraint(equalToConstant: 470).isActive = true
        let row = NSStackView(views: [title, control])
        row.spacing = 10
        return row
    }

    /// 业务作用：插入方式只开放对应参数，未选择的数值字段不能阻止固定文字输入。
    /// 参数说明: 无。
    /// 返回：当前模式和填充方式对应的控件可用性立即生效。
    @objc private func updateAvailability() {
        let numeric = mode.indexOfSelectedItem == 0
        for control in [start, step, repetitions, width] {
            control.isEnabled = numeric
        }
        radix.isEnabled = numeric
        padding.isEnabled = numeric
        uppercase.isEnabled = numeric && radix.indexOfSelectedItem == 3
        width.isEnabled = numeric && padding.indexOfSelectedItem != 0
        textRow?.isHidden = numeric
    }

    /// 业务作用：参数无效时在原表单保留全部输入，只有完整确认后才交回列编辑计划。
    /// 参数说明: 无。
    /// 返回：有效固定文本或数字格式；取消、关闭均不产生正文副作用。
    func run() -> ColumnInsertionValue? {
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                if mode.indexOfSelectedItem == 1 {
                    guard !text.isEditingInput, !text.stringValue.isEmpty,
                        text.stringValue.utf8.count <= 1_048_576
                    else {
                        throw NateError.message("请先结束全文编辑与候选，固定文本须为一至 1 MiB。")
                    }
                    return .text(text.stringValue)
                }
                let bases = [2, 8, 10, 16]
                guard bases.indices.contains(radix.indexOfSelectedItem),
                    ColumnNumberPadding.allCases.indices.contains(padding.indexOfSelectedItem)
                else {
                    throw NateError.message("请选择完整数字格式。")
                }
                let base = bases[radix.indexOfSelectedItem]
                guard
                    let first = Int64(
                        start.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        radix: base
                    ),
                    let increment = Int64(
                        step.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        radix: base
                    ),
                    let count = Int(repetitions.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                    let minimum = padding.indexOfSelectedItem == 0
                        ? 0 : Int(width.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    throw NateError.message("数字参数无效：起始值和步长须符合所选进制，次数和宽度须为十进制整数。")
                }
                let format = ColumnNumberFormat(
                    start: first,
                    step: increment,
                    radix: base,
                    repetitions: count,
                    padding: ColumnNumberPadding.allCases[padding.indexOfSelectedItem],
                    minimumWidth: minimum,
                    uppercase: uppercase.state == .on
                )
                _ = try format.render(count: 0)
                return .numbers(format)
            }
            catch {
                feedback.stringValue = error.localizedDescription
            }
        }
        return nil
    }
}
