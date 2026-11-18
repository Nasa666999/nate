import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage

extension ApplicationController {
    /// 业务作用：为所有 UI 入口提供唯一语义路由，正文写入统一使用内核事务。
    /// 参数说明:
    /// - id: 稳定动作标识及必要的资源标识。
    /// 返回：执行动作或明确反馈实际失败。
    func route(_ id: String) {
        // 退出已固定保护集合，期间只允许观察和撤销，不再增加正文或路径副作用。
        guard
            !closing
                || ["fileTasks", "cancelReads", "cancelExternalCommand", "lastExternalOutput"].contains(id)
        else {
            return
        }
        if id.hasPrefix("edit:"), let command = TextCommand(rawValue: String(id.dropFirst(5))) {
            edit(command)
            return
        }
        if id.hasPrefix("markStyle:"), let command = styleMarkAction(for: id) {
            routeStyleMark(command.style, action: command.action)
            return
        }
        if id.hasPrefix("language:"), let active {
            active.language = String(id.dropFirst(9))
            active.languageExplicit = true
            mainWindow?.editor.refresh()
            refreshUI()
            return
        }
        if id.hasPrefix("projectPanel:"), let index = Int(id.dropFirst("projectPanel:".count)) {
            showProjectPanel(index)
            return
        }
        if id.hasPrefix("encoding:"), let index = Int(id.dropFirst(9)) {
            Task {
                await convertEncoding(index)
            }
            return
        }
        if id.hasPrefix("reinterpret:"), let index = Int(id.dropFirst(12)),
            TextEncoding.available.indices.contains(index), let active
        {
            Task {
                await reload(active, encoding: TextEncoding.available[index])
            }
            return
        }
        if id.hasPrefix("recent:") {
            Task {
                await openFile(URL(fileURLWithPath: String(id.dropFirst(7))))
            }
            return
        }
        if id.hasPrefix("activate:"), let uuid = UUID(uuidString: String(id.dropFirst(9))) {
            activate(uuid)
            return
        }
        if id.hasPrefix("tool:") {
            runTextTool(String(id.dropFirst(5)))
            return
        }
        if let action = foldAction(for: id) {
            mainWindow?.editor.performFold(action)
            return
        }
        switch id {
        case "matchingBracket": mainWindow?.editor.navigateBracket(.jump)
        case "selectBracketPair": mainWindow?.editor.navigateBracket(.selectPair)
        case "selectInsideBracket": mainWindow?.editor.navigateBracket(.selectInside)
        case "new":
            _ = newDocument()
            buildMenus()
        case "open":
            let urls = SystemIntegration.chooseFiles()
            Task {
                for url in urls {
                    await openFile(url)
                }
            }
        case "save":
            mainWindow?.editor.finishComposition()
            guard let active else {
                return
            }
            Task {
                if active.url == nil {
                    await saveAs(active)
                }
                else {
                    _ = await flush(active)
                }
            }
        case "saveAs", "saveCopy":
            if let active {
                Task {
                    await saveAs(active, copy: id == "saveCopy")
                }
            }
        case "saveAll":
            Task {
                for document in documents where document.url != nil {
                    _ = await flush(document)
                }
                _ = await flushRecovery()
            }
        case "resolveSaveState":
            Task {
                await resolveSaveState()
            }
        case "pausedWorkspaces":
            Task {
                await showPausedWorkspaces()
            }
        case "reload":
            if let active {
                Task {
                    await reload(active)
                }
            }
        case "close":
            if let activeID {
                Task {
                    await closeDocument(activeID)
                }
            }
        case "closeAll", "closeOthers", "closeClean", "closeUnpinned": closeGroup(id)
        case "reopenClosed":
            Task {
                await reopenClosed()
            }
        case "recoveryArchive":
            Task {
                await showRecoveryArchive()
            }
        case "undo", "redo":
            if let input = NSApp.keyWindow?.firstResponder as? NSTextView {
                if id == "undo" {
                    input.undoManager?.undo()
                }
                else {
                    input.undoManager?.redo()
                }
            }
            else {
                mainWindow?.editor.finishComposition()
                if id == "undo" {
                    active?.buffer.undo()
                }
                else {
                    active?.buffer.redo()
                }
                mainWindow?.editor.refresh(reveal: true)
                didEdit()
            }
        case "find", "replace", "findFiles", "findProjects":
            presentFind(
                replacing: id == "replace",
                inFiles: id == "findFiles",
                inProjects: id == "findProjects"
            )
        case "incrementalSearch": showIncrementalSearch()
        case "findMark": presentMarkPage()
        case "nextSearchMark", "previousSearchMark":
            navigateDocumentMarks(.search, backwards: id == "previousSearchMark")
        case "clearSearchMarks": clearSearchMarks()
        case "copySearchMarks": copyDocumentMarks(styles: [.search])
        case "clearStyleMarks":
            clearDocumentStyles(
                DocumentMarkStyle.allCases.filter {
                    $0 != .search
                }
            )
        case "clearAllMarks": clearDocumentStyles(DocumentMarkStyle.allCases)
        case "copyStyleMarks":
            copyDocumentMarks(
                styles: DocumentMarkStyle.allCases.filter {
                    $0 != .search
                }
            )
        case "copyAllMarks": copyDocumentMarks(styles: DocumentMarkStyle.allCases)
        case "styleMatchCase", "styleWholeWord": toggleStyleMarkPreference(id)
        case "showSearchResults": mainWindow?.showSearchResultHistory()
        case "showToolOutput": mainWindow?.showToolOutput()
        case "hideResults": mainWindow?.setResultsVisible(false)
        case "closeIncrementalSearch": closeIncrementalSearch()
        case "incrementalNext", "incrementalPrevious":
            if let window = mainWindow, window.isIncrementalSearchVisible {
                window.incrementalSearch.publishQuery()
                searchIncrementally(
                    window.incrementalSearch.query,
                    options: window.incrementalSearch.options,
                    previous: id == "incrementalPrevious"
                )
            }
        case "findNext", "findPrevious":
            if let window = mainWindow, let nativeWindow = window.window, window.isIncrementalSearchVisible,
                NSApp.keyWindow === nativeWindow
                    || (nativeWindow.attachedSheet != nil && nativeWindow.attachedSheet === NSApp.keyWindow)
            {
                // 增量栏及其全文草稿拥有当前输入；草稿未确认时不借全局匹配命令执行另一份查询。
                guard !window.incrementalSearch.isEditingInput else {
                    return
                }
                window.incrementalSearch.publishQuery()
                searchIncrementally(
                    window.incrementalSearch.query,
                    options: window.incrementalSearch.options,
                    previous: id == "findPrevious"
                )
                return
            }
            if findWindow == nil {
                presentFind(replacing: false)
            }
            if let options = findWindow?.options {
                search(id == "findNext" ? "next" : "previous", options: options, directory: "", filters: "")
            }
        case "compositionBegan":
            suspendSearchForInput()
        case "compositionEnded":
            refreshVisibleIncrementalHighlights()
        case "selectionChanged":
            // 用户位置和克隆焦点属于新的导航意图，等待中的旧增量结果不得再选择原位置。
            if incrementalTask != nil {
                cancelIncrementalSearch(resetOrigin: true)
                mainWindow?.incrementalSearch.feedback.stringValue = "光标或视图已改变，请继续查找。"
            }
            searchNavigationEvidence = nil
            searchNavigationGeneration = UUID()
            cancelCompletion()
            activeID = mainWindow?.editor.document.id
            refreshVisibleIncrementalHighlights()
            if findWindow?.page != .files {
                _ = refreshSearchPresentation()
            }
            refreshUI()
        case "complete", "completeWords", "completeLanguage", "signature": requestCompletion(id)
        case "typingAssistance": requestCompletion(automatic: true)
        case "completePath": requestPathCompletion()
        case "cancelReads": readIO.cancelReads()
        case "cancelExternalCommand": externalCommandTask?.cancel()
        case "fileTasks": showFileTasks()
        case "lastExternalOutput":
            if let output = lastExternalOutput {
                mainWindow?.showResults(output)
            }
        case "assistancePreferences": showAssistancePreferences()
        case "wrap":
            mainWindow?.editor.wrapLines.toggle()
            mainWindow?.editor.refresh()
        case "symbols":
            mainWindow?.editor.showSymbols.toggle()
            mainWindow?.editor.needsDisplay = true
        case "zoomIn", "zoomOut", "zoomReset":
            if let editor = mainWindow?.editor {
                let size =
                    id == "zoomReset"
                    ? 13 : max(7, min(72, editor.font.pointSize + (id == "zoomIn" ? 1 : -1)))
                editor.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                editor.refresh()
            }
        case "themeLight":
            NSApp.appearance = NSAppearance(named: .aqua)
            mainWindow?.editor.refresh()
        case "themeDark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
            mainWindow?.editor.refresh()
        case "themeSystem":
            NSApp.appearance = nil
            mainWindow?.editor.refresh()
        case "fullscreen": mainWindow?.window?.toggleFullScreen(nil)
        case "overwrite":
            mainWindow?.editor.overwrite.toggle()
            refreshUI()
        case "rtl":
            mainWindow?.editor.rtl.toggle()
            mainWindow?.editor.refresh()
        case "pin":
            active?.pinned.toggle()
            refreshUI()
        case "readOnly":
            if let active {
                setReadOnly(active, value: !active.buffer.isReadOnly)
            }
        case "nextTab", "previousTab": cycleTab(forward: id == "nextTab")
        case "goto": gotoLine()
        case "importUDL": importUDL()
        case "exportUDL": exportUDL()
        case "newUDL": editUDL(creating: true)
        case "editUDL": editUDL(creating: false)
        case "duplicateUDL": duplicateUDL()
        case "deleteUDL":
            Task {
                await deleteUDL()
            }
        case "openSelection", "revealSelection", "openURL": openSelection(id)
        case "bookmark", "nextBookmark", "previousBookmark", "clearBookmarks", "invertBookmarks",
            "copyBookmarks", "deleteBookmarks", "deleteUnbookmarked", "cutBookmarks", "replaceBookmarks",
            "cancelBookmarkAction":
            bookmarkCommand(id)
        case "comment", "blockComment": comment(block: id == "blockComment")
        case "selectMatches", "addMatch": selectMatches(all: id == "selectMatches")
        case "moveLineUp", "moveLineDown", "blankAbove", "blankBelow": lineCommand(id)
        case "dateTime":
            insert(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
        case "columnEditor": columnEditor()
        case "statistics": statistics()
        case "rememberClipboard":
            if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1_048_576 {
                clipboardHistory = Array(
                    ([text]
                        + clipboardHistory.filter {
                            !$0.utf8.elementsEqual(text.utf8)
                        }).prefix(20)
                )
            }
        case "clipboardHistory": showClipboardHistory()
        case "recordMacro":
            macroRecording.toggle()
            if macroRecording {
                macroActions = []
            }
            refreshUI()
        case "playMacro":
            Task {
                await playMacro(repetitions: 1)
            }
        case "repeatMacro":
            if let value = SystemIntegration.prompt("重复宏", "输入执行次数（1–10000）", initial: "10"),
                let count = Int(value)
            {
                Task {
                    await playMacro(repetitions: max(1, min(10000, count)))
                }
            }
        case "saveMacro": saveMacro()
        case "loadMacro": loadMacro()
        case "run": configureRun()
        case "saveSession":
            Task {
                await saveSession()
            }
        case "openSession":
            if let url = SystemIntegration.chooseFiles().first {
                Task {
                    await loadSession(url)
                }
            }
        case "openAllRecent":
            Task {
                for path in recentFiles {
                    await openFile(URL(fileURLWithPath: path))
                }
            }
        case "clearRecent":
            recentFiles = []
            buildMenus()
        case "folder": chooseFolder()
        case "refreshFolder": directoryWorkspace?.refresh()
        case "closeFolder": directoryWorkspace?.stop()
        case "monitor":
            Task {
                await toggleMonitoring()
            }
        case "rename":
            Task {
                await renameDocument()
            }
        case "trash":
            Task {
                await trashDocument()
            }
        case "splitVertical", "splitHorizontal": mainWindow?.splitEditor(vertical: id == "splitVertical")
        case "unsplit": mainWindow?.removeSplit()
        case "symbolsList": showSymbols()
        case "refreshStructure": requestStructure(force: true)
        case "closeStructure": closeStructure()
        case "detectLanguage":
            if let active {
                active.language =
                    registry?.detect(
                        filename: active.name,
                        firstLine: active.buffer.text.text(in: active.buffer.text.lineRange(0))
                    ) ?? "normal"
                active.languageExplicit = false
                mainWindow?.editor.refresh()
                refreshUI()
            }
        case "print": printDocument()
        case "pageSetup": NSPageLayout().runModal()
        case "exportHTML", "exportRTF": exportDocument(html: id == "exportHTML")
        case "markdownPreview": previewMarkdown()
        case "compare": compareDocuments()
        case "characterConverter": characterConverter()
        case "preferences": showPreferences()
        case "saveBackupPreferences": showSaveBackupPreferences()
        case "savedBackups": showSavedBackups()
        case "about":
            SystemIntegration.alert("Nate", "原生 macOS 文本与代码编辑器\nSwift · AppKit · TextKit 2\nGPL-3.0-or-later")
        case "help":
            SystemIntegration.alert(
                "使用 Nate",
                "⌘N 新建，⌘O 打开，⌘S 立即保存。\nCtrl+H 或 ⌘⇧H 打开替换。\n默认每秒自动保存已修改文件；临时文档写入独立恢复目录。\nOption 拖动建立列选，⌘ 单击添加光标。\n编码菜单区分重新解释与转换；外部冲突时暂停覆盖。"
            )
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    /// 业务作用：标签上下文动作明确使用被点击身份，不能误操作活动文档。
    /// 参数说明:
    /// - id: 被点击文档。
    /// - action: 上下文命令。
    /// 返回：按该文档执行动作。
    func tabAction(_ id: UUID, _ action: String) {
        // 退出期间允许任务观察，但标签动作不能另建关闭流程或修改已经固定的恢复元数据。
        guard !closing else {
            return
        }
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        switch action {
        case "close":
            Task {
                await closeDocument(id)
            }
        case "pin":
            document.pinned.toggle()
            refreshUI()
        case "copyPath":
            if let path = document.url?.path {
                SystemIntegration.copy(path)
            }
        case "reveal":
            if let url = document.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case "clone":
            activate(id)
            mainWindow?.splitEditor(vertical: true)
        default: closeGroup(action, reference: id)
        }
    }
}
