import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：菜单启用与选中状态反映当前焦点和编辑权限。
    /// 参数说明:
    /// - menuItem: 待验证项目。
    /// 返回：只读文档不能执行正文写入，查找框撤销保持自身上下文。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = menuItem.representedObject as? String else {
            return true
        }
        if id.hasPrefix("activate:") {
            let fields =
                menuItem.identifier?.rawValue.split(separator: ".", omittingEmptySubsequences: false) ?? []
            guard let documentID = UUID(uuidString: String(id.dropFirst("activate:".count))),
                fields.count == 2, let source = UUID(uuidString: String(fields[0])),
                UUID(uuidString: String(fields[1])) == documentID,
                source == mainWindow?.tabOrderIdentity,
                workspaceTabIDs(in: mainWindow).contains(documentID),
                documents.contains(where: {
                    $0.buffer.id == documentID
                })
            else {
                return false
            }
            menuItem.state = documentID == activeID ? .on : .off
            return !closing
        }
        if id.hasPrefix("documentListOrder:") {
            guard !closing, let window = mainWindow, !documents.isEmpty,
                menuItem.identifier?.rawValue == window.tabOrderIdentity.uuidString,
                let order = DocumentListOrder(rawValue: String(id.dropFirst("documentListOrder:".count)))
            else {
                return false
            }
            menuItem.state = window.documentListOrder == order ? .on : .off
            return true
        }
        if id == "documentList" {
            return !closing && mainWindow != nil && !documents.isEmpty
        }
        if id == "newWindow" || id == "cloneToWindow" {
            return !closing && editorWindows.count < 32
                && (id == "newWindow" ? documents.count < 1024 : active?.closing == false)
        }
        if id == "moveTabToWindow" {
            return !closing && editorWindows.count > 1 && active?.closing == false
        }
        if id.hasPrefix("tabLayout:") {
            guard let mode = DocumentTabLayout(rawValue: String(id.dropFirst("tabLayout:".count))) else {
                return false
            }
            menuItem.state = mainWindow?.documentTabLayout == mode ? .on : .off
            return !closing && mainWindow != nil
        }
        if id.hasPrefix("savedRun:") {
            return !closing && runCommands.ready && runCommands.task == nil
                && runCommands.prepareTask == nil && runCommands.importTask == nil
                && externalCommandTask == nil && active != nil
                && runCommands.library.commands.contains(where: {
                    "savedRun:" + $0.id.uuidString == id
                })
        }
        if let enabled = validateClipboardMenu(menuItem, id: id) {
            return enabled
        }
        if id == "cancelTextTool" {
            return textTools.task != nil || digests.task != nil
        }
        if id == "characterConverter" || id == "hexConversionSettings" {
            return !closing && mainWindow?.hasMarkedEditorInput != true
        }
        if id.hasPrefix("digest:") {
            guard !closing, mainWindow?.hasMarkedEditorInput != true else {
                return false
            }
            if id.hasSuffix(":selection") {
                guard textTools.task == nil, let (_, _, editor) = quickFindContext(),
                    let state = editor.viewSelectionState, state.entries.count == 1,
                    case .stream = state.shape, let entry = state.entries.first,
                    !entry.selection.range.isEmpty, entry.selection.virtualColumn == 0
                else {
                    return false
                }
                return true
            }
            return digests.task == nil
        }
        if ["print", "printImmediately", "printSelection", "printSettings", "pageSetup"].contains(id) {
            guard !closing, !printing.busy, let document = active, !document.closing,
                !document.buffer.isEditingSuspended, mainWindow?.hasMarkedEditorInput == false
            else {
                return false
            }
            if id == "printSelection" {
                guard let (_, _, editor) = quickFindContext(), let state = editor.viewSelectionState,
                    state.entries.count == 1, case .stream = state.shape,
                    let entry = state.entries.first, !entry.selection.range.isEmpty,
                    entry.selection.virtualColumn == 0
                else {
                    return false
                }
            }
            return true
        }
        if id.hasPrefix("tool:") {
            let digest = ["tool:md5", "tool:sha1", "tool:sha256", "tool:sha512"].contains(id)
            guard textTools.task == nil, let (document, _, editor) = quickFindContext(),
                digest || !document.buffer.isReadOnly,
                let state = editor.viewSelectionState, state.entries.count == 1,
                case .stream = state.shape, state.entries.first?.selection.virtualColumn == 0
            else {
                return false
            }
            return true
        }
        if let enabled = validateMacroMenu(menuItem, id: id) {
            return enabled
        }
        if id == "resetSidebarRecovery" {
            return !closing && recovery != nil && !sidebarRecovery.loading && sidebarRecovery.task == nil
        }
        if id == "pausedWorkspaces" {
            return !closing && applicationSupport != nil && pausedWorkspace.task == nil
        }
        if id == "cancelPausedWorkspaceImport" {
            return !closing && pausedWorkspace.task != nil && !pausedWorkspace.published
        }
        if id == "columnEditor" {
            return !closing && columnEditing.task == nil && quickFindContext() != nil
                && active?.buffer.isReadOnly == false
        }
        if ["rectangleLeft", "rectangleRight", "rectangleUp", "rectangleDown"].contains(id) {
            return !closing && quickFindContext()?.2.canExtendRectangle == true
        }
        if id == "cancelColumnEditor" {
            return columnEditing.task != nil
        }
        if id == "cancelLineSort" {
            return lineSorting.task != nil
        }
        if id == "lineSort" || id.hasPrefix("sort:") {
            return lineSorting.task == nil && quickFindContext() != nil && active?.buffer.isReadOnly == false
        }
        if id == "cancelHistoryAction" {
            return historyAction.task != nil
        }
        if let enabled = validateStyleMarkMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateBookmarkMenu(id) {
            return enabled
        }
        if let enabled = validateSelectedTextHighlightMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateQuickFindMenu(id) {
            return enabled
        }
        if id == "searchOnInternet" {
            return webSearchAvailable()
        }
        if let enabled = validateConfigurationAndComparisonMenu(id) {
            return enabled
        }
        if let enabled = validateScrollSynchronizationMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateMultipleSelectionMenu(menuItem, id: id) {
            return enabled
        }
        if let action = foldAction(for: id) {
            guard !closing, let window = mainWindow, NSApp.keyWindow === window.window,
                let editor = NSApp.keyWindow?.firstResponder as? EditorView, editor === window.editor
            else {
                return false
            }
            return editor.foldingAvailable(action)
        }
        if ["matchingBracket", "selectBracketPair", "selectInsideBracket"].contains(id) {
            guard !closing, let window = mainWindow, NSApp.keyWindow === window.window,
                let editor = NSApp.keyWindow?.firstResponder as? EditorView, editor === window.editor,
                !editor.document.isEditingSuspended
            else {
                return false
            }
            switch id {
            case "matchingBracket": return editor.bracketNavigationAvailable(.jump)
            case "selectBracketPair": return editor.bracketNavigationAvailable(.selectPair)
            default: return editor.bracketNavigationAvailable(.selectInside)
            }
        }
        if id.hasPrefix("language:") {
            menuItem.state = active?.language == String(id.dropFirst(9)) ? .on : .off
        }
        if id == "readOnly" {
            menuItem.state = active?.buffer.isReadOnly == true ? .on : .off
        }
        if id == "wrap" {
            menuItem.state = mainWindow?.editor.wrapLines == true ? .on : .off
        }
        if id == "indentGuides" || id == "longLineGuide" {
            let selected =
                id == "indentGuides"
                ? mainWindow?.editor.showIndentGuides == true : mainWindow?.editor.longLineColumn != nil
            menuItem.state = selected ? .on : .off
            return !closing && mainWindow != nil
        }
        if id == "modificationHistory" {
            menuItem.state = mainWindow?.editor.showModificationHistory == true ? .on : .off
            return !closing && mainWindow != nil
        }
        if id == "previousModification" || id == "nextModification" {
            return quickFindContext(allowingStaleRectangle: true) != nil
                && active?.buffer.modificationSnapshot != nil
        }
        if id == "symbols" {
            menuItem.state = mainWindow?.editor.showSymbols == true ? .on : .off
        }
        if id == "symbolsList" {
            menuItem.state = mainWindow?.isStructureVisible == true ? .on : .off
        }
        if id == "cancelExternalCommand" {
            return externalCommandTask != nil
        }
        if id == "lastExternalOutput" {
            return lastExternalOutput != nil
        }
        if id == "undo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo
                ?? (historyAction.task == nil && quickFindContext() != nil && active?.buffer.canUndo == true)
        }
        if id == "redo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo
                ?? (historyAction.task == nil && quickFindContext() != nil && active?.buffer.canRedo == true)
        }
        if id.hasPrefix("edit:") || ["comment", "blockComment", "columnEditor"].contains(id) {
            return active?.buffer.isReadOnly == false
        }
        if ["trash", "rename", "reload", "monitor"].contains(id) {
            return active?.url != nil
        }
        return true
    }
}
