import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：视图菜单保存完整修改历史显示偏好，关闭显示不清除记录或重置缩放与选择。
    /// 参数说明: 无。
    /// 返回：合法偏好同步全部克隆；未知归档只临时切换，保留原配置供完整设置处理。
    func toggleModificationHistory() {
        guard !closing, let window = mainWindow else {
            return
        }
        let current = currentDisplaySettings()
        let enabled = !window.editor.showModificationHistory
        do {
            let settings = try EditorDisplaySettings(
                fontName: current.fontName,
                fontSize: current.fontSize,
                appearance: current.appearance,
                wrapLines: current.wrapLines,
                showSymbols: current.showSymbols,
                showIndentGuides: window.editor.showIndentGuides,
                longLineColumn: window.editor.longLineColumn ?? current.longLineColumn,
                showLongLineGuide: window.editor.longLineColumn != nil,
                showModificationHistory: enabled,
                textLinks: current.textLinks
            )
            // 单项显示动作没有解释未知归档的权限，只有完整设置表单能明确重建这份偏好。
            if displayPreferences.sourceValid {
                try saveDisplaySettings(settings, updateViews: false)
            }
            window.setModificationHistory(enabled)
            window.status.stringValue =
                displayPreferences.sourceValid
                ? "修改历史显示设置已保存，正文与记录保持。"
                : "原显示配置无法读取，修改历史显示仅本次生效。"
        }
        catch {
            window.status.stringValue = "修改历史显示设置未保存：" + error.localizedDescription
        }
    }

    /// 业务作用：前后修改导航复验实际正文焦点、完整分类和原选择，后台就绪不能抢回后来移动的光标。
    /// 参数说明:
    /// - backwards: 为真定位当前行之前的修改，否则定位当前行之后的修改。
    /// 返回：来源保持时定位最近修改行并展开遮挡；没有候选或来源变化时正文与选择保持。
    func navigateModification(backwards: Bool) {
        guard let (document, window, editor) = quickFindContext(allowingStaleRectangle: true),
            let source = document.buffer.modificationSnapshot,
            let selection = editor.primarySelection
        else {
            return
        }
        let text = document.buffer.text
        let line = text.lineNumber(at: selection.head)
        let start =
            backwards
            ? text.lineStart(line)
            : (line + 1 < text.lineCount ? text.lineStart(line + 1) : text.byteCount + 1)
        resultNavigationTask?.cancel()
        resultNavigationGeneration = UUID()
        let request = resultNavigationGeneration
        let selected = editor.selectionGeneration
        let focus = editor.focusGeneration
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled,
                self.resultNavigationGeneration == request,
                let (active, actualWindow, actualEditor) = self.quickFindContext(
                    allowingStaleRectangle: true
                ),
                active === document, actualWindow === window, actualEditor === editor,
                editor.selectionGeneration == selected, editor.focusGeneration == focus,
                document.buffer.revision == source.revision,
                document.buffer.modificationSnapshot?.generation == source.generation
            else {
                return false
            }
            return true
        }
        resultNavigationTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.resultNavigationGeneration == request {
                    self.resultNavigationTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try source.nearestPosition(from: start, backwards: backwards)
                }
                let position = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 焦点、保存分类和选择都可能在正文修订不变时改变，失去任一原证据就停止旧导航。
                guard current() else {
                    return
                }
                guard let position else {
                    window.status.stringValue = backwards ? "当前行之前没有其它修改。" : "当前行之后没有其它修改。"
                    return
                }
                let target = text.lineNumber(at: min(position, text.byteCount))
                editor.setCaret(text.lineStart(target))
                window.status.stringValue = "已定位修改行 \(target + 1)"
            }
            catch {
                if current() {
                    window.status.stringValue = "修改导航未执行：" + error.localizedDescription
                }
            }
        }
    }
}
