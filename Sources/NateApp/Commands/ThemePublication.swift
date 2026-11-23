import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：完整主题库先编码并固定选中项，再复验原偏好来源，单次发布全部视图。
    /// 参数说明:
    /// - library: 用户明确应用或已授权来源热更新的完整候选。
    /// - generation: 候选所属的原主题偏好代次。
    /// - source: 候选取得时的完整原偏好证据。
    /// - restartWatching: 明确配置改变时重建监视，当前热更新沿原监视资格继续。
    /// 返回：完整库保存并同步全部现有视图；失败不发布部分主题。
    func publishThemeLibrary(
        _ library: EditorThemeLibrary,
        generation: UUID,
        source: NSDictionary,
        restartWatching: Bool = true
    ) async throws {
        let runtime = themePreferences
        let domain = runtime.defaults ?? .standard
        let prepared = try await runtime.io.readCancellable {
            token in
            let data = try library.encoded(permit: {
                !token.isCancelled
            })
            let selected = library.entries.first(where: {
                $0.id == library.selectedID
            })
            let snapshot = try selected.map {
                try EditorThemeSnapshot(
                    $0.definition,
                    permit: {
                        !token.isCancelled
                    }
                )
            }
            return (data, snapshot)
        }
        // 偏好与布局必须来自同一完整候选；来源、关闭和取消在任何写入与视图发布之前复验。
        guard !closing, !Task.isCancelled, runtime.generation == generation,
            (runtime.defaults ?? .standard) === domain,
            source.isEqual(themePreferenceSource(domain))
        else {
            throw NateError.message("主题来源已经改变，旧草稿未保存，请重新打开。")
        }
        domain.set(prepared.0, forKey: "editorThemeLibrary")
        guard domain.data(forKey: "editorThemeLibrary") == prepared.0 else {
            runtime.loaded = false
            throw NateError.message("完整主题库保存未确认，当前显示保持原状。")
        }
        let changesAppearance = runtime.compiled?.identity != prepared.1?.identity
        runtime.generation = UUID()
        runtime.loaded = true
        runtime.sourceValid = true
        runtime.sourceDomain = domain
        runtime.source = themePreferenceSource(domain)
        runtime.library = library
        runtime.compiled = prepared.1
        runtime.warning = runtime.bundledWarning
        if changesAppearance {
            cancelCompletion()
            mainWindow?.setEditorTheme(prepared.1)
        }
        if restartWatching {
            restartThemeWatching()
        }
        refreshUI()
        mainWindow?.status.stringValue =
            prepared.1.map {
                "主题已应用 · " + $0.definition.name
            } ?? "已恢复系统与原资源样式。"
    }

    /// 业务作用：主题表单只保存自己打开时的完整偏好来源，文件任务和当前正文分别持有权限。
    /// 参数说明: 无。
    /// 返回：用户明确应用后发布完整主题，取消或来源失配保持原偏好。
    func showThemePreferences() {
        let runtime = themePreferences
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        guard runtime.presentationTask == nil else {
            runtime.form?.showWindow(nil)
            return
        }
        runtime.presentationTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                runtime.form = nil
                runtime.presentationTask = nil
            }
            await self.loadThemeLibrary()
            guard !self.closing, !Task.isCancelled, let library = runtime.library else {
                return
            }
            let domain = runtime.defaults ?? .standard
            guard let source = runtime.source, runtime.sourceDomain === domain else {
                return
            }
            let generation = runtime.generation
            let form = ThemePreferencesWindow(
                library: runtime.pendingDraft ?? library,
                languages: self.registry?.languages ?? [],
                userLanguages: self.userLanguages,
                styleNames: runtime.styleNames,
                warning: runtime.pendingDraft == nil ? runtime.warning : "先前草稿未保存，已保留供检查；应用将保存这份完整草稿。",
                importer: {
                    [weak self] url in
                    guard let self, !self.closing else {
                        throw CancellationError()
                    }
                    return try await self.readTheme(at: url)
                },
                exporter: {
                    [weak self] definition, url in
                    guard let self, !self.closing else {
                        throw CancellationError()
                    }
                    try await self.exportTheme(definition, to: url)
                }
            )
            runtime.form = form
            guard let selected = await form.present(for: self.mainWindow?.window), !self.closing,
                !Task.isCancelled
            else {
                runtime.pendingDraft = nil
                return
            }
            do {
                try await self.publishThemeLibrary(selected, generation: generation, source: source)
                runtime.pendingDraft = nil
            }
            catch {
                runtime.pendingDraft = selected
                self.mainWindow?.status.stringValue = error.localizedDescription
            }
        }
    }
}
