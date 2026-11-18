import Foundation
import NateUI

private struct SearchResultRemovalSelection {
    var batch = false
    var files: Set<UUID> = []
    var hits: [UUID: Set<UUID>] = [:]
    var notes: Set<Int> = []
}

extension ApplicationController {
    /// 业务作用：结果保留策略使用搜索设置的受保护保存通道，历史清理不授予未知归档覆盖权。
    /// 参数说明:
    /// - preferences: 用户明确设置的结果策略。
    /// 返回：面板、查找窗口及待保存快照一致，当前历史和执行请求不变。
    func setSearchResultPreferences(_ preferences: SearchResultPreferences) {
        mainWindow?.searchResults.setPreferences(preferences)
        if let findWindow {
            findWindow.setResultPreferences(preferences)
        }
        var state = findWindow?.state ?? searchSettingsState
        state.results = preferences
        scheduleSearchSettings(state)
    }

    /// 业务作用：按稳定批次、文件或命中身份删除展示元数据，同时保留原始查询选项和匹配统计。
    /// 参数说明:
    /// - requests: 单次用户选择的完整删除集合，父级选择包含筛选隐藏的后代。
    /// 返回：完整新树验证后收回对应定位权；无效或过量请求保留原历史，源文件不受影响。
    func removeSearchResults(_ requests: [SearchResultRemoval]) {
        guard requests.count <= 100_000 else {
            return
        }
        var selections: [UUID: SearchResultRemovalSelection] = [:]
        var hitCount = 0
        for request in requests {
            switch request {
            case .batch(let batch): selections[batch, default: SearchResultRemovalSelection()].batch = true
            case .file(let batch, let file):
                selections[batch, default: SearchResultRemovalSelection()].files.insert(file)
            case .hits(let batch, let file, let hits):
                guard hits.count <= 100_000 - hitCount else {
                    return
                }
                hitCount += hits.count
                selections[batch, default: SearchResultRemovalSelection()].hits[file, default: []].formUnion(
                    hits
                )
            case .note(let batch, let index):
                selections[batch, default: SearchResultRemovalSelection()].notes.insert(index)
            }
        }
        var candidate: [SearchResultBatchState] = []
        var changed = false
        do {
            for batch in resultBatches {
                let original = batch.presentation
                guard let selection = selections[original.id] else {
                    candidate.append(batch)
                    continue
                }
                if selection.batch {
                    changed = true
                    continue
                }
                var files: [SearchResultFilePresentation] = []
                var destinations = batch.destinations
                for file in original.files {
                    if selection.files.contains(file.id) {
                        changed = true
                        for row in file.rows {
                            destinations.removeValue(forKey: row.id)
                        }
                        continue
                    }
                    let removed = selection.hits[file.id] ?? []
                    let rows = file.rows.filter {
                        !removed.contains($0.id)
                    }
                    if rows.count == file.rows.count {
                        files.append(file)
                        continue
                    }
                    changed = true
                    for row in file.rows where removed.contains(row.id) {
                        destinations.removeValue(forKey: row.id)
                    }
                    if !rows.isEmpty {
                        files.append(
                            SearchResultFilePresentation(
                                id: file.id,
                                name: file.name,
                                path: file.path,
                                matchCount: file.matchCount,
                                rows: rows
                            )
                        )
                    }
                }
                let notes = original.notes.enumerated().filter {
                    !selection.notes.contains($0.offset)
                }.map(\.element)
                changed = changed || notes.count != original.notes.count
                let presentation = SearchResultBatchPresentation(
                    id: original.id,
                    query: original.query,
                    scope: original.scope,
                    files: files,
                    notes: notes,
                    condition: original.condition,
                    initialMatchCount: original.initialMatchCount
                )
                let footprint = try presentation.validatedFootprint()
                candidate.append(
                    SearchResultBatchState(
                        presentation: presentation,
                        destinations: destinations,
                        footprint: footprint,
                        matchCount: original.initialMatchCount
                    )
                )
            }
            guard changed else {
                return
            }
            // 元数据删除先撤销旧导航；等待中的读取不能在新树发布之后恢复被删命中的焦点权限。
            resultNavigationGeneration = UUID()
            resultNavigationTask?.cancel()
            resultNavigationTask = nil
            try mainWindow?.presentSearchResults(candidate.map(\.presentation))
            resultBatches = candidate
            if let latest = candidate.first {
                resultNavigation = latest.presentation.files.flatMap(\.rows).compactMap {
                    latest.destinations[$0.id]
                }
            }
            else {
                resultNavigation = []
            }
        }
        catch {
            mainWindow?.status.stringValue = error.localizedDescription
        }
    }
}
