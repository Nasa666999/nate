import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：无选区整行与插入换行适配分别恢复，缺省保持整行启用、换行适配关闭。
    /// 参数说明:
    /// - defaults: 应用实际使用的偏好存储。
    /// 返回：仅恢复明确布尔值，读取配置不采集剪贴板正文。
    func loadClipboardOptions(from defaults: UserDefaults) {
        clipboardDefaults = defaults
        copyLineWithoutSelection = defaults.object(forKey: "copyLineWithoutSelection") as? Bool ?? true
        adaptClipboardLineEndings = defaults.object(forKey: "adaptClipboardLineEndings") as? Bool ?? false
        historyPersistence.enabled = defaults.object(forKey: "persistClipboardHistory") as? Bool ?? false
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
        clipboardHistory = ClipboardHistoryLimits.inserting(record, into: clipboardHistory)
        scheduleClipboardHistoryPersistence()
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：浏览完整历史的形态与全文，持久化须经明确选项，面板不轮询系统剪贴板。
    /// 参数说明: 无。
    /// 返回：显示独立面板，粘贴前回到实际活动编辑器复验来源和权限。
    func showClipboardHistory() {
        guard !closing, mainWindow != nil else {
            return
        }
        if historyPersistence.panel == nil {
            let panel = ClipboardHistoryPanel()
            panel.onPaste = {
                [weak self] record in self?.pasteClipboardHistoryRecord(record)
            }
            panel.onClear = {
                [weak self] in self?.clearClipboardHistory()
            }
            panel.onPersistenceChange = {
                [weak self] in self?.setClipboardHistoryPersistence($0)
            }
            panel.onResetArchive = {
                [weak self] in self?.resetClipboardHistoryArchive()
            }
            historyPersistence.panel = panel
        }
        refreshClipboardHistoryPanel()
        historyPersistence.panel?.showWindow(nil)
        historyPersistence.panel?.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：用户明确选中的完整记录只粘贴到当前活动文档，面板行号不会重解释为其它内容。
    /// 参数说明:
    /// - record: 面板实际选中的稳定记录与完整载荷。
    /// 返回：恢复真实正文焦点后执行常规原子粘贴，失效、候选或权限不足时保留正文与剪贴板。
    func pasteClipboardHistoryRecord(_ record: ClipboardHistoryRecord) {
        guard !closing,
            clipboardHistory.contains(where: {
                $0.id == record.id
            }),
            let active, let window = mainWindow, window.editor.document === active.buffer,
            !window.editor.hasComposition, !active.buffer.isReadOnly, !active.buffer.isEditingSuspended
        else {
            return
        }
        window.window?.makeKeyAndOrderFront(nil)
        guard window.window?.makeFirstResponder(window.editor) == true,
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
        case "clipboardHistory": return !closing && mainWindow != nil
        case "clearClipboardHistory": return !closing && !clipboardHistory.isEmpty
        case "cancelClipboard": return !closing && mainWindow != nil
        case "pasteAsPlainText":
            guard let editor = quickFindContext()?.2 else {
                return false
            }
            return editor.validateMenuItem(
                NSMenuItem(title: "", action: #selector(EditorView.pasteAsPlainText(_:)), keyEquivalent: "")
            )
        case "pasteHTMLSource": return quickFindContext()?.2.specialPasteAvailable(.htmlSource) == true
        case "pasteRTFSource": return quickFindContext()?.2.specialPasteAvailable(.rtfSource) == true
        case "pasteBinary": return quickFindContext()?.2.specialPasteAvailable(.binary) == true
        case "copyBinary", "cutBinary":
            guard let editor = quickFindContext()?.2 else {
                return false
            }
            let selector = id == "copyBinary" ? #selector(EditorView.copy(_:)) : #selector(EditorView.cut(_:))
            return editor.validateMenuItem(
                NSMenuItem(
                    title: "",
                    action: selector,
                    keyEquivalent: ""
                )
            )
        default: return nil
        }
    }
}
