import AppKit
import NateCore

@MainActor
final class MacroRecordingRuntime {
    static let maximumBytes = 64 * 1024 * 1024
    var retainedBytes = 0
    var source: UUID?
    var failure: String?
    private var skippedIDs: Set<String> = []
    private var skipped: [String] = []
    private var additionalSkipped = false

    /// 业务作用：录制预算和未录制提示独立于正文、临时动作及磁盘宏库。
    /// 参数说明: 无。
    /// 返回：空预算、没有错误和未录制记录的状态。
    init() {}

    /// 业务作用：一份新临时宏开始后解除上一份录制的预算缓存和提示，不沿用旧动作的估计。
    /// 参数说明: 无。
    /// 返回：预算在下一项动作前按当前完整列表重新建立。
    func reset() {
        retainedBytes = 0
        source = nil
        failure = nil
        skippedIDs = []
        skipped = []
        additionalSkipped = false
    }

    /// 业务作用：不支持录制的明确命令保留有界提示，重复触发不让状态文本和索引无限增长。
    /// 参数说明:
    /// - id: 明确命令的稳定身份。
    /// - title: 原生菜单或动作的用户名称。
    /// 返回：最多保留十六项名称，更多命令用统一提示表示，不记录正文或完整配置。
    func noteSkipped(_ id: String, title: String) {
        guard !skippedIDs.contains(id) else {
            return
        }
        guard skipped.count < 16 else {
            additionalSkipped = true
            return
        }
        skippedIDs.insert(id)
        let name = title.unicodeScalars.prefix(128).map {
            $0.value < 32 || $0.value == 127 || $0.properties.generalCategory == .lineSeparator
                || $0.properties.generalCategory == .paragraphSeparator ? " " : String($0)
        }.joined()
        skipped.append(name)
    }

    /// 业务作用：状态栏和宏管理持续展示同一录制结果，普通状态刷新不能静默清除遗漏说明。
    /// 参数说明: 无。
    /// 返回：停止原因优先，否则显示有界未录制命令名称；全部完整录制时为空。
    var notice: String? {
        if let failure {
            return failure
        }
        guard !skipped.isEmpty else {
            return nil
        }
        return "未录制命令：" + skipped.prefix(3).joined(separator: "、")
            + (additionalSkipped ? "等多项。" : skipped.count > 3 ? "等 \(skipped.count) 项。" : "。")
    }
}

extension ApplicationController {
    /// 业务作用：所有成功语义动作共用完整录制预算，超限停止录制并保留此前动作，不截断当前动作内容。
    /// 参数说明:
    /// - action: 实际业务动作已完成后提供的完整语义。
    /// 返回：完整追加为真；播放、停止、无效或超限为假，正文及已经记录的动作保持原状。
    @discardableResult
    func appendRecordedMacroAction(_ action: MacroAction) -> Bool {
        guard macroRecording, !macroPlaying else {
            return false
        }
        let runtime = macroRecorder
        do {
            try action.validateSupport()
            guard macroActions.count < MacroArchive.maximumActions else {
                throw NateError.message("动作达到一万项。")
            }
            if runtime.source != macroActionsGeneration {
                var bytes = 0
                for existing in macroActions {
                    let cost = existing.retainedByteEstimate()
                    guard cost <= MacroRecordingRuntime.maximumBytes - bytes else {
                        throw NateError.message("完整动作估计保留容量超过 64 MiB。")
                    }
                    bytes += cost
                }
                runtime.retainedBytes = bytes
            }
            let cost = action.retainedByteEstimate()
            guard cost <= MacroRecordingRuntime.maximumBytes - runtime.retainedBytes else {
                throw NateError.message("完整动作估计保留容量超过 64 MiB。")
            }
            macroActions.append(action)
            runtime.retainedBytes += cost
            runtime.source = macroActionsGeneration
            return true
        }
        catch {
            // 当前业务动作已经完成；停止新的录制权限，不能丢弃此前列表或声称本次也已记录。
            macroRecording = false
            runtime.failure = "宏录制已停止：" + error.localizedDescription + "本次动作未录入，已有动作及正文保留。"
            refreshUI()
            refreshMacroLibraryPresentation()
            return false
        }
    }

    /// 业务作用：明确支持的语义动作和录制控制不产生遗漏提示，其它真实菜单命令持续说明未录制。
    /// 参数说明:
    /// - id: 当前统一菜单命令身份，内部状态通知没有对应菜单项。
    /// 返回：只登记可见命令，不执行、暂停或重放任何正文动作。
    func noteUnrecordedMacroCommand(_ id: String) {
        guard macroRecording, !macroPlaying, !id.hasPrefix("edit:"), !id.hasPrefix("sort:") else {
            return
        }
        let quiet: Set<String> = [
            "recordMacro", "save", "saveAll", "saveAs", "saveCopy", "fileTasks",
            "find", "replace", "findFiles", "findProjects", "findMark", "findNext", "findPrevious",
            "pasteAsPlainText", "clipboardHistory", "cancelClipboard", "macroLibrary",
            "pasteHTMLSource", "pasteRTFSource", "pasteBinary", "copyBinary", "cutBinary",
            "lineSort", "cancelLineSort", "selectionChanged", "typingAssistance", "compositionBegan",
            "compositionEnded", "clipboardBegan", "unrecordedEditorCommand",
        ]
        guard !quiet.contains(id) else {
            return
        }
        if let title = menuCommandTitle(id) {
            macroRecorder.noteSkipped(id, title: title)
            refreshUI()
            refreshMacroLibraryPresentation()
        }
    }
}
