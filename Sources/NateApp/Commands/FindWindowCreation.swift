import AppKit
import NateUI

extension ApplicationController {
    /// 业务作用：按需建立并恢复共享查找窗口，快捷搜索可保存当前条件而不显示窗口或转移焦点。
    /// 参数说明: 无。
    /// 返回：现有或完成回调装配的新窗口；归档无效时使用有效默认设置并保留错误状态。
    func ensureFindWindow() -> FindReplaceWindow {
        if let findWindow {
            findWindow.setWordBoundaries(mainWindow?.editor.wordBoundaries ?? currentWordBoundaries())
            return findWindow
        }
        let window = FindReplaceWindow()
        do {
            try window.restore(searchSettingsState)
        }
        catch {
            searchSettingsError = error.localizedDescription
        }
        window.setWordBoundaries(mainWindow?.editor.wordBoundaries ?? currentWordBoundaries())
        if searchSettingsURL != nil {
            window.onStateChange = {
                [weak self] state in
                self?.scheduleSearchSettings(state)
                self?.mainWindow?.refreshSelectedTextHighlights()
            }
            window.onResetSavedState = {
                [weak self] state in
                self?.resetSearchSettings(state)
            }
        }
        window.onAction = {
            [weak self] action, options, directory, filters in
            self?.search(action, options: options, directory: directory, filters: filters)
        }
        window.onInputBegan = {
            [weak self] in self?.suspendSearchForInput()
        }
        window.onSelectionContextRequest = {
            [weak self] in
            _ = self?.refreshSearchPresentation()
        }
        window.onDismiss = {
            [weak self] in
            self?.mainWindow?.window?.makeKeyAndOrderFront(nil)
            if let editor = self?.mainWindow?.editor {
                self?.mainWindow?.window?.makeFirstResponder(editor)
            }
        }
        findWindow = window
        return window
    }
}
