import AppKit
import NateCore
import NatePlatform
import NateSyntax
import NateUI

extension ApplicationController {
    /// 业务作用：将实际文档与保存通道状态显示到标签、标题和状态栏。
    /// 参数说明: 无。
    /// 返回：不更改焦点、选区或视口。
    func refreshUI() {
        guard let active, let window = mainWindow else {
            return
        }
        let words = currentWordBoundaries()
        let wordRulesChanged = window.editor.wordBoundaries != words
        if wordRulesChanged {
            // 外部偏好更改与显式设置具有相同发布边界，旧规则计算不能在新规则下继续导航。
            cancelQuickFind()
            cancelMultipleSelection()
            cancelIncrementalSearch(resetOrigin: true)
        }
        window.setWordBoundaries(words)
        window.setDelimiterSelectionSettings(currentDelimiterSelectionSettings())
        findWindow?.setWordBoundaries(words)
        if wordRulesChanged {
            refreshVisibleIncrementalHighlights()
        }
        window.refreshSelectedTextHighlights()
        window.updateTabs(
            documents.map {
                TabPresentation(
                    id: $0.buffer.id,
                    title: $0.name,
                    path: $0.url?.path,
                    selected: $0.buffer.id == activeID,
                    pinned: $0.pinned,
                    dirty: $0.isDirty,
                    failed: $0.failure != nil || $0.recoveryError != nil,
                    readOnly: $0.buffer.isReadOnly
                )
            }
        )
        window.window?.title = active.name + " — Nate"
        window.window?.representedURL = active.url
        window.editor.language = registry?.language(active.language)
        if active.language == "markdown" {
            let dark = window.editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            window.editor.userLanguage =
                userLanguages[dark ? "udl:Markdown (preinstalled dark mode)" : "udl:Markdown (preinstalled)"]
        }
        else {
            window.editor.userLanguage = userLanguages[active.language]
        }
        applyCurrentTabSettings()
        window.setIndentationSettings(currentIndentationSettings())
        window.setPairInsertionSettings(currentPairSettings())
        let head = active.buffer.primarySelection?.head ?? 0
        let line = active.buffer.text.lineNumber(at: head)
        let lineStart = active.buffer.text.lineStart(line)
        let column: String
        if head - lineStart > 1_048_576 {
            // 超长行状态更新不能在每次输入时复制整段前缀，单位在界面中明确标出。
            column =
                "\((active.buffer.text.utf16Offset(byte: head) ?? 0) - (active.buffer.text.utf16Offset(byte: lineStart) ?? 0) + 1) UTF-16"
        }
        else {
            column = String(active.buffer.text.text(in: ByteRange(lineStart, head)).count + 1)
        }
        let selectionCount = active.buffer.selections.reduce(0) {
            $0 + $1.range.count
        }
        let state: String
        if let recoveryError = active.recoveryError {
            state =
                "⚠ 恢复保存失败：" + recoveryError
                + (active.failure.map {
                    "；原文件：" + $0
                } ?? "")
        }
        else if let operation = active.saveOperation?.snapshot, operation.finished == nil {
            state = fileTaskStatus(operation) + " · " + fileTaskStage(operation.stage)
        }
        else if let failure = active.failure {
            state = (active.recoveryRevision == active.buffer.revision ? "恢复副本已保存；原文件：" : "⚠ 原文件：") + failure
        }
        else {
            state = active.isDirty ? "待保存" : active.state
        }
        let protection = !recoveryReady ? "⚠ 恢复保护不可用 · " : !autosaveEnabled ? "自动保存已暂停 · " : ""
        let suspension =
            active.editingSuspensionStatus.map {
                $0 + " │ "
            } ?? ""
        let recoveryState =
            active.url != nil && recoveryReady && active.recoveryError == nil
            ? " · " + (active.recoveryRevision == active.buffer.revision ? "恢复正文已保存" : "恢复正文待保存") : ""
        let structureState: String
        if window.editor.document.id == active.buffer.id {
            let editor = window.editor
            let structure: String? =
                editor.layoutAnalysisStatus ?? editor.rectangleLayoutStatus ?? editor.bracketAnalysisStatus
                ?? editor.foldingAnalysisStatus
            let syntax: String? = structure ?? editor.syntaxAnalysisStatus
            let marks: String? = syntax ?? editor.markDisplayStatus
            let temporary: String? = marks ?? editor.textHighlightDisplayStatus
            let selected: String? =
                temporary ?? editor.selectedTextHighlightStatus ?? editor.referenceGuideStatus
            let preferences: String? =
                selected ?? selectedTextPreferences.failure ?? tabPreferences.warning ?? tabPreferences
                .layoutWarning
                ?? indentationPreferences.warning
                ?? pairPreferences.warning
            let files: String? =
                preferences ?? fileOpeningPreferences.warning ?? fileOpeningPreferences.recentWarning
            let configuration: String? =
                files ?? documentComparison.failure ?? userConfiguration.failure
                ?? userConfiguration.searchWarning
            let sidebar: String? = configuration ?? sidebarRecovery.failure
            let importing: String? = pausedWorkspace.task != nil ? "正在导入保留工作区…" : nil
            let matching: String? = sidebar ?? multipleSelection.failure
            let status: String? = matching ?? pausedWorkspace.failure ?? importing
            structureState =
                status.map {
                    " · " + $0
                } ?? ""
        }
        else {
            structureState = ""
        }
        let folded = window.editor.foldedRegionCount
        let foldState = folded > 0 ? " · 已收起 \(folded) 处" : ""
        window.status.stringValue =
            "  \(suspension)\(registry?.language(active.language)?.name ?? active.language)  │  Ln \(line + 1), Col \(column)  ·  选区 \(selectionCount) B / \(active.buffer.selections.count)  │  \(active.encoding.name)  │  \(active.buffer.text.lineCount) 行 · \(active.buffer.text.byteCount) B  │  \(window.editor.overwrite ? "OVR" : "INS")  │  \(protection)\(state)\(recoveryState)\(structureState)\(foldState)"
            + (macroRecorder.notice.map {
                " │ " + $0
            } ?? "")
        if window.isStructureVisible {
            requestStructure()
        }
    }
}
