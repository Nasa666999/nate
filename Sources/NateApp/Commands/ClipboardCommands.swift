import AppKit
import NateCore
import NateUI

struct ClipboardHistoryRecord: Sendable {
    let payload: ClipboardPayload
    let text: String
    let retainedBytes: Int

    /// 业务作用：历史仅保留容量内完整载荷，不能为预览而丢弃形态或截断正文。
    /// 参数说明:
    /// - payload: 用户主动复制、剪切或粘贴的实际完整内容。
    /// 返回：文本与编码合计不超过 1 MiB 的记录；超量不进入历史。
    init(_ payload: ClipboardPayload) throws {
        guard payload.plainByteCount <= 1_048_576 else {
            throw NateError.message("该剪贴板内容超过单条历史容量。")
        }
        let data = try payload.encoded()
        guard data.count + payload.plainByteCount <= 1_048_576 else {
            throw NateError.message("该剪贴板内容与形态超过单条历史容量。")
        }
        self.payload = payload
        text = try payload.plainText()
        retainedBytes = data.count + payload.plainByteCount
    }
}

extension ApplicationController {
    /// 业务作用：无选区整行与插入换行适配分别恢复，缺省保持整行启用、换行适配关闭。
    /// 参数说明:
    /// - defaults: 应用实际使用的偏好存储。
    /// 返回：仅恢复明确布尔值，读取配置不采集剪贴板正文。
    func loadClipboardOptions(from defaults: UserDefaults) {
        clipboardDefaults = defaults
        copyLineWithoutSelection = defaults.object(forKey: "copyLineWithoutSelection") as? Bool ?? true
        adaptClipboardLineEndings = defaults.object(forKey: "adaptClipboardLineEndings") as? Bool ?? false
    }

    /// 业务作用：用户明确切换选项时先撤销旧准备，克隆视图不能沿原选项继续发布。
    /// 参数说明:
    /// - id: 整行或插入换行适配的稳定菜单标识。
    /// 返回：当前窗口一致生效，并仅向已选择的偏好存储写入布尔设置。
    func toggleClipboardOption(_ id: String) {
        if id == "clipboardCopyLine" {
            copyLineWithoutSelection.toggle()
            clipboardDefaults?.set(copyLineWithoutSelection, forKey: "copyLineWithoutSelection")
        }
        else if id == "clipboardAdaptEndings" {
            adaptClipboardLineEndings.toggle()
            clipboardDefaults?.set(adaptClipboardLineEndings, forKey: "adaptClipboardLineEndings")
        }
        else {
            return
        }
        mainWindow?.setClipboardOptions(
            copyLine: copyLineWithoutSelection,
            adaptEndings: adaptClipboardLineEndings
        )
    }

    /// 业务作用：仅在用户主动剪贴板动作完成后保留完整内容，历史受数量和总容量双重限制。
    /// 参数说明:
    /// - payload: 已实际完成动作的完整载荷。
    /// 返回：精确相同载荷移到最近位置，最多二十条且总计不超过 8 MiB；超大内容保持在系统剪贴板中。
    func rememberClipboard(_ payload: ClipboardPayload) {
        guard let record = try? ClipboardHistoryRecord(payload) else {
            return
        }
        var candidates =
            [record]
            + clipboardHistory.filter {
                $0.payload != payload
            }
        var bytes = 0
        candidates = Array(
            candidates.prefix(20).prefix {
                value in
                guard value.retainedBytes <= 8_388_608 - bytes else {
                    return false
                }
                bytes += value.retainedBytes
                return true
            }
        )
        clipboardHistory = candidates
    }

    /// 业务作用：查看本次运行中主动动作产生的完整历史，显示形态和不可见字符预览。
    /// 参数说明: 无。
    /// 返回：选择记录后按其原形态进入常规原子粘贴，不读取系统剪贴板。
    func showClipboardHistory() {
        guard let (_, _, editor) = quickFindContext() else {
            return
        }
        let menu = NSMenu()
        for (index, record) in clipboardHistory.enumerated() {
            let preview = String(String.UnicodeScalarView(record.text.unicodeScalars.prefix(80)))
                .replacingOccurrences(of: "\r", with: "␍")
                .replacingOccurrences(of: "\n", with: "↵")
                .replacingOccurrences(of: "\t", with: "⇥")
                .replacingOccurrences(of: "\0", with: "␀")
            let kind: String
            switch record.payload.shape {
            case .stream: kind = "片段"
            case .lines: kind = "整行"
            case .rectangle: kind = "矩形"
            }
            let item = NSMenuItem(
                title: "\(index + 1). [\(kind)] \(preview)",
                action: #selector(pasteHistory(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = record
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 50), in: editor)
    }

    /// 业务作用：菜单持有明确完整记录，异步历史变化不能把原选择的序号重解释为另一条正文。
    /// 参数说明:
    /// - sender: 带完整记录的实际菜单选择。
    /// 返回：原编辑视图按当前明确换行选项执行一次完整粘贴，系统剪贴板保持不变。
    @objc func pasteHistory(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? ClipboardHistoryRecord,
            let (_, _, editor) = quickFindContext()
        else {
            return
        }
        let adapt = adaptClipboardLineEndings
        Task {
            _ = await editor.pastePayload(record.payload, adaptLineEndings: adapt)
        }
    }

    /// 业务作用：剪贴板设置反映真实选中状态，历史和编辑动作只在正文焦点下启用。
    /// 参数说明:
    /// - item: 即将呈现的真实菜单项。
    /// - id: 当前稳定菜单动作标识。
    /// 返回：本组件动作的可用性，其它动作为空。
    func validateClipboardMenu(_ item: NSMenuItem, id: String) -> Bool? {
        switch id {
        case "clipboardCopyLine":
            item.state = copyLineWithoutSelection ? .on : .off
            return !closing
        case "clipboardAdaptEndings":
            item.state = adaptClipboardLineEndings ? .on : .off
            return !closing
        case "clipboardHistory": return !closing && !clipboardHistory.isEmpty && quickFindContext() != nil
        case "clearClipboardHistory": return !closing && !clipboardHistory.isEmpty
        case "cancelClipboard": return !closing && mainWindow != nil
        case "pasteAsPlainText":
            guard let editor = quickFindContext()?.2 else {
                return false
            }
            return editor.validateMenuItem(
                NSMenuItem(title: "", action: #selector(EditorView.pasteAsPlainText(_:)), keyEquivalent: "")
            )
        default: return nil
        }
    }
}
