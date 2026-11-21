import AppKit
import NateCore

extension EditorView {
    /// 业务作用：原生键盘和宏使用相同编辑意图，只有完整成功后才记录，失败不能继续后续动作。
    /// 参数说明:
    /// - command: 已明确识别的方向、选择、删除、换行、Tab 或标签结束符输入意图。
    /// 返回：正文或选择成功完成时为真，合法边界上的无变化也为真；保护、候选或准备失败为假。
    @discardableResult
    public func performEditorCommand(_ command: EditorCommand) -> Bool {
        guard !document.isEditingSuspended else {
            onStatus?("文档处于编辑保护，输入与选择保持原状。")
            return false
        }
        // 候选必须先真实确认，方向和删除均不能沿尚未提交的显示坐标继续。
        guard finishComposition() else {
            return false
        }
        let succeeded: Bool
        switch command {
        case .deleteBackward: succeeded = delete(forward: false)
        case .deleteForward: succeeded = delete(forward: true)
        case .insertTab: succeeded = insertConfiguredTab()
        case .insertNewline: succeeded = insertConfiguredNewline()
        case .insertMarkupTagEnd: succeeded = insertMarkupTagEnd()
        case .moveLeft: succeeded = move(horizontal: -1)
        case .moveRight: succeeded = move(horizontal: 1)
        case .moveUp: succeeded = move(vertical: -1)
        case .moveDown: succeeded = move(vertical: 1)
        case .extendLeft: succeeded = move(horizontal: -1, extend: true)
        case .extendRight: succeeded = move(horizontal: 1, extend: true)
        case .extendUp: succeeded = move(vertical: -1, extend: true)
        case .extendDown: succeeded = move(vertical: 1, extend: true)
        case .lineStart: succeeded = move(edge: -1)
        case .lineEnd: succeeded = move(edge: 1)
        case .extendLineStart: succeeded = move(edge: -1, extend: true)
        case .extendLineEnd: succeeded = move(edge: 1, extend: true)
        case .wordLeft: succeeded = moveWord(forward: false)
        case .wordRight: succeeded = moveWord(forward: true)
        case .extendWordLeft: succeeded = moveWord(forward: false, extend: true)
        case .extendWordRight: succeeded = moveWord(forward: true, extend: true)
        case .documentStart, .documentEnd, .extendDocumentStart, .extendDocumentEnd:
            let end = command == .documentEnd || command == .extendDocumentEnd
            let extend = command == .extendDocumentStart || command == .extendDocumentEnd
            let position = end ? document.text.byteCount : 0
            viewSelections = viewSelections.map {
                TextSelection(anchor: extend ? $0.anchor : position, head: position)
            }
            succeeded = true
        case .selectAll:
            viewSelections = [TextSelection(anchor: 0, head: document.text.byteCount)]
            succeeded = true
        case .collapseSelection:
            guard let primarySelection else {
                return false
            }
            viewSelections = [primarySelection]
            succeeded = true
        }
        guard succeeded else {
            return false
        }
        if ![EditorCommand.deleteBackward, .deleteForward, .insertTab, .insertNewline, .insertMarkupTagEnd]
            .contains(command)
        {
            clearRectangularSelection()
            needsDisplay = true
            revealSelection()
            onSelection?()
        }
        onEditorCommand?(command)
        return true
    }

    /// 业务作用：系统文字选择器只映射明确支持的语义，不将未知选择器存入可执行宏。
    /// 参数说明:
    /// - name: AppKit 输入上下文解析出的选择器名称。
    /// 返回：对应的方向、删除、选择、换行或 Tab 输入意图，非本组命令为空。
    static func semanticCommand(_ name: String) -> EditorCommand? {
        switch name {
        case "deleteBackward:": return .deleteBackward
        case "deleteForward:": return .deleteForward
        case "insertTab:": return .insertTab
        case "insertNewline:": return .insertNewline
        case "moveLeft:", "moveBackward:": return .moveLeft
        case "moveRight:", "moveForward:": return .moveRight
        case "moveUp:": return .moveUp
        case "moveDown:": return .moveDown
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": return .extendLeft
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:": return .extendRight
        case "moveUpAndModifySelection:": return .extendUp
        case "moveDownAndModifySelection:": return .extendDown
        case "moveToBeginningOfLine:", "moveToBeginningOfParagraph:", "moveToLeftEndOfLine:":
            return .lineStart
        case "moveToEndOfLine:", "moveToEndOfParagraph:", "moveToRightEndOfLine:": return .lineEnd
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:",
            "moveToBeginningOfParagraphAndModifySelection:":
            return .extendLineStart
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
            "moveToEndOfParagraphAndModifySelection:":
            return .extendLineEnd
        case "moveToBeginningOfDocument:": return .documentStart
        case "moveToEndOfDocument:": return .documentEnd
        case "moveToBeginningOfDocumentAndModifySelection:": return .extendDocumentStart
        case "moveToEndOfDocumentAndModifySelection:": return .extendDocumentEnd
        case "moveWordLeft:", "moveWordBackward:": return .wordLeft
        case "moveWordRight:", "moveWordForward:": return .wordRight
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": return .extendWordLeft
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": return .extendWordRight
        case "selectAll:": return .selectAll
        case "cancelOperation:": return .collapseSelection
        default: return nil
        }
    }
}
