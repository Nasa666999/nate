import AppKit

extension EditorView: NSMenuItemValidation {
    /// 业务作用：原生剪贴板菜单遵守实际焦点、完整选择、候选和只读权限，不把禁用操作留给提交阶段。
    /// 参数说明:
    /// - menuItem: 系统即将呈现的真实菜单项。
    /// 返回：当前语义可执行时启用；只检查剪贴板类型，不读取其正文。
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        let selected =
            viewSelectionState != nil && selectionStateRevision == document.revision
            && !hasStaleRectangleLayout
        switch menuItem.action {
        case #selector(copy(_:)):
            return focused && selected && composition == nil
        case #selector(cut(_:)):
            return focused && selected && composition == nil && !document.isReadOnly
                && !document.isEditingSuspended
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            guard focused, selected, composition == nil, !document.isReadOnly, !document.isEditingSuspended
            else {
                return false
            }
            let types: [NSPasteboard.PasteboardType] =
                menuItem.action == #selector(pasteAsPlainText(_:))
                ? [.string] : [ClipboardRuntime.type, ClipboardRuntime.legacyType, .string]
            return NSPasteboard.general.availableType(from: types) != nil
        case #selector(selectAll(_:)):
            return focused && composition == nil && !document.isEditingSuspended
        default:
            return true
        }
    }
}
