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

    /// 业务作用：菜单启动实际修改导航，只有成功定位才把语义写入仍在进行的同一份宏。
    /// 参数说明:
    /// - navigation: 用户明确选择的实际方向。
    /// 返回：安排异步导航，当前完整分类不可用或意图变化时保留原选择。
    func navigateModification(_ navigation: ModificationNavigation) {
        guard let navigate = prepareModificationNavigation(navigation) else {
            return
        }
        let request = resultNavigationGeneration
        let recording = macroRecording && !macroPlaying ? macroRecordingGeneration : nil
        resultNavigationTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if resultNavigationGeneration == request {
                    resultNavigationTask = nil
                }
            }
            if await navigate(), let recording, macroRecordingGeneration == recording {
                appendRecordedMacroAction(.command(navigation.rawValue))
            }
        }
    }

    /// 业务作用：宏使用播放时的实际修改分类与主光标，并等待定位发布后才继续。
    /// 参数说明:
    /// - navigation: 归档中的真实修改导航语义。
    /// 返回：选择确实移动到对应物理行时为真，无候选、失权或取消时停止后续动作。
    func playModificationNavigation(_ navigation: ModificationNavigation) async -> Bool {
        guard let navigate = prepareModificationNavigation(navigation) else {
            return false
        }
        return await navigate()
    }

    /// 业务作用：在菜单或播放动作交出控制之前固定原分类、焦点和选择，后台只返回最近位置。
    /// 参数说明:
    /// - navigation: 本次动作采用的确切方向。
    /// 返回：可等待的同源导航；它实际发布完整行定位时才为真，其它情况不修改选择。
    private func prepareModificationNavigation(_ navigation: ModificationNavigation) -> (
        @MainActor () async -> Bool
    )? {
        guard !Task.isCancelled,
            let (document, window, editor) = quickFindContext(allowingStaleRectangle: true),
            let selection = editor.primarySelection
        else {
            return nil
        }
        guard let source = document.buffer.modificationSnapshot else {
            window.status.stringValue = "当前完整修改分类尚不可用。"
            return nil
        }
        let request = UUID()
        // 先撤销旧意图再通知工作取消，即使旧计算同时完成也无法发布。
        resultNavigationGeneration = request
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        let text = document.buffer.text
        let line = text.lineNumber(at: selection.head)
        let backwards = navigation == .previous
        let start =
            backwards
            ? text.lineStart(line)
            : (line + 1 < text.lineCount ? text.lineStart(line + 1) : text.byteCount + 1)
        let selected = editor.selectionGeneration
        let focus = editor.focusGeneration
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled, !self.closing,
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
        return {
            guard current() else {
                return false
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
                // 分类、焦点及选择可能在同一正文修订下改变，缺少原证据时不能交付旧坐标。
                guard current() else {
                    return false
                }
                guard let position else {
                    window.status.stringValue = backwards ? "当前行之前没有其它修改。" : "当前行之后没有其它修改。"
                    return false
                }
                let target = text.lineNumber(at: min(position, text.byteCount))
                editor.setCaret(text.lineStart(target))
                window.status.stringValue = "已定位修改行 \(target + 1)"
                return true
            }
            catch {
                if current() {
                    window.status.stringValue = "修改导航未执行：" + error.localizedDescription
                }
                return false
            }
        }
    }
}
