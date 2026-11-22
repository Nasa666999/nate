import AppKit
import NateCore
import NateSearch
import NateUI

extension ApplicationController {
    /// 业务作用：配置变化不越过候选输入、完整表达式草稿、搜索任务或已准备的历史动作。
    /// 参数说明: 无。
    /// 返回：工作区可完整接受偏好变更时为真，不确认输入、不取消已授权的写入动作。
    func canApplyUserConfiguration() -> Bool {
        !closing && mainWindow != nil && mainWindow?.hasMarkedEditorInput != true
            && mainWindow?.incrementalSearch.isEditingInput != true && findWindow?.isEditingInput != true
            && searchTask == nil && historyAction.task == nil && !macroPlaying
    }

    /// 业务作用：完整合法的导入只进入待审阅状态，当前偏好和全部文档保持原状。
    /// 参数说明:
    /// - candidate: 已完成容器校验的完整配置。
    /// - name: 用户选择文件的显示名称。
    /// 返回：语义全部有效时固定候选及当前来源，失败不保存或部分采用。
    func stageUserConfiguration(_ candidate: UserConfiguration, name: String) throws {
        guard canApplyUserConfiguration() else {
            throw NateError.message("当前输入、搜索或历史动作尚未收束，请完成后再导入配置。")
        }
        let source = try configurationSource()
        let candidate = try UserConfigurationSchema.preservingRecoveryPolicy(candidate, source: source)
        try UserConfigurationSchema.validate(candidate)
        let runtime = userConfiguration
        runtime.preview = candidate
        runtime.previewName = name
        runtime.source = source
        runtime.sourceDomain = configurationDefaults()
        runtime.sourceGenerations = configurationGenerationProof()
        runtime.previewGeneration = runtime.generation
        runtime.failure = nil
    }

    /// 业务作用：来源与语义复验先于整份偏好域发布，界面失败时整份恢复原域，不能留下部分导入。
    /// 参数说明: 无。
    /// 返回：完整候选一次进入偏好域并同步界面；任何门禁失败均保留原域，界面同步失败执行完整补偿。
    func applyUserConfigurationPreview() throws {
        let runtime = userConfiguration, domain = configurationDefaults()
        guard canApplyUserConfiguration(), let candidate = runtime.preview, let source = runtime.source,
            runtime.previewGeneration == runtime.generation, runtime.sourceDomain === domain,
            runtime.sourceGenerations == configurationGenerationProof(), try configurationSource() == source
        else {
            throw NateError.message("当前偏好或输入状态已经改变，旧配置预览未应用，请重新导入。")
        }
        try UserConfigurationSchema.validate(candidate)
        let oldSearch = findWindow?.state ?? searchSettingsState
        let oldPreferences = SearchUserPreferences(state: oldSearch)
        let searchPreferences: SearchUserPreferences
        if let entry = candidate.entries.first(where: {
            $0.key == "searchUserPreferences"
        }), case .bytes(let data) = entry.value {
            searchPreferences = try SearchUserPreferences.decode(data)
        }
        else {
            searchPreferences = SearchUserPreferences(state: SearchWindowState())
        }
        try searchPreferences.validate()
        let original = domain.persistentDomain(forName: runtime.domainName) ?? [:]
        var updated = original
        for entry in candidate.entries {
            switch entry.value {
            case .unset: updated.removeValue(forKey: entry.key)
            case .boolean(let value): updated[entry.key] = value
            case .integer(let value): updated[entry.key] = value
            case .decimal(let value): updated[entry.key] = value
            case .text(let value): updated[entry.key] = value
            case .bytes(let value): updated[entry.key] = value
            }
        }
        // 所有字段及来源已确认，整个应用域在同一执行域内一次替换，不逐项发布新旧混合配置。
        domain.setPersistentDomain(updated, forName: runtime.domainName)
        do {
            try synchronizeUserConfiguration(search: searchPreferences, searchState: oldSearch)
        }
        catch {
            // 持久偏好先整体回到原域，再恢复呈现；补偿不改写正文、输入原文或文档格式。
            domain.setPersistentDomain(original, forName: runtime.domainName)
            do {
                try synchronizeUserConfiguration(search: oldPreferences, searchState: oldSearch)
            }
            catch {
                throw NateError.message("原偏好域已恢复，部分界面未能重新装配，请重新打开窗口。")
            }
            throw NateError.message("配置未应用，原偏好已恢复：" + error.localizedDescription)
        }
        runtime.generation = UUID()
        clearUserConfigurationPreview()
        runtime.failure = nil
        buildMenus()
        refreshUI()
        mainWindow?.status.stringValue = "用户配置已完整应用，正文、原文输入与独立资源保持原状。"
    }

    /// 业务作用：偏好域完成发布后同步各实际视图，旧交互计划先失权，已有作业仍使用各自固定快照。
    /// 参数说明:
    /// - search: 已完整验证的可迁移搜索偏好。
    /// - searchState: 本次操作前固定的查询、目录、历史与页面状态。
    /// 返回：界面和未来动作使用完整新偏好，正文、编码、选区、保存点与撤销历史不被修改。
    private func synchronizeUserConfiguration(search: SearchUserPreferences, searchState: SearchWindowState)
        throws
    {
        cancelQuickFind()
        cancelMultipleSelection()
        cancelIncrementalSearch(resetOrigin: true)
        cancelCompletion()
        displayPreferences.loaded = false
        tabPreferences.loaded = false
        indentationPreferences.loaded = false
        pairPreferences.loaded = false
        wordPreferences.loaded = false
        delimiterPreferences.loaded = false
        dateTimePreferences.loaded = false
        dateTimePreferences.generation = UUID()
        fileOpeningPreferences.loaded = false
        fileOpeningPreferences.generation = UUID()
        webSearch.loaded = false
        webSearch.generation = UUID()
        printing.loaded = false
        printing.generation = UUID()
        selectedTextPreferences.options = SelectedTextHighlightOptions()
        selectedTextPreferences.generation = UUID()
        selectedTextPreferences.failure = nil
        multipleSelection.options = MultipleSelectionOptions()
        multipleSelection.failure = nil
        let domain = configurationDefaults()
        loadClipboardOptions(from: domain)
        loadIncrementalOptions(from: domain)
        loadMultipleSelectionOptions(from: domain)
        loadSelectedTextHighlightOptions(from: domain)
        loadSaveBackupPolicy()
        loadRecoveryStoragePolicy()
        if let window = mainWindow {
            loadEditorPreferences(into: window)
            window.structurePanel.loadSortingPreferences(from: domain)
            window.incrementalSearch.prepare(query: nil, options: incrementalOptions)
        }
        applyCurrentTabSettings()
        mainWindow?.setIndentationSettings(currentIndentationSettings())
        mainWindow?.setPairInsertionSettings(currentPairSettings())
        let boundaries = currentWordBoundaries()
        mainWindow?.setWordBoundaries(boundaries)
        mainWindow?.setDelimiterSelectionSettings(currentDelimiterSelectionSettings())
        searchSettingsState = search.applying(to: searchState)
        try findWindow?.applyUserPreferences(search)
        findWindow?.setWordBoundaries(boundaries)
        mainWindow?.searchResults.setPreferences(search.results)
        mainWindow?.refreshSelectedTextHighlights()
    }

    /// 业务作用：丢弃尚未应用的候选及来源，不改变实际偏好或用户文档。
    /// 参数说明: 无。
    /// 返回：配置预览回到空状态，候选不再拥有后续发布资格。
    func clearUserConfigurationPreview() {
        userConfiguration.preview = nil
        userConfiguration.previewName = nil
        userConfiguration.source = nil
        userConfiguration.sourceDomain = nil
        userConfiguration.sourceGenerations = []
        userConfiguration.previewGeneration = nil
    }
}
