import AppKit
import NateCore
import NateSearch
import NateUI

extension ApplicationController {
    /// 业务作用：当前文档查询以独立颜色组保留完整匹配，可明确附加书签而不改变正文或搜索结果历史。
    /// 参数说明:
    /// - document: 用户发起标记时的真实文档。
    /// - options: 已确认的完整查找条件。
    /// - input: 原输入窗口与配置的运行期身份。
    /// - generation: 统一搜索任务的本次请求身份。
    /// 返回：后台全部计划通过正文、颜色、书签与输入复验后同步发布，失效计划保留已有颜色与正文。
    func highlightSearchMatches(
        _ document: WorkspaceDocument,
        options: SearchOptions,
        input: SearchRequestInput,
        generation: UUID
    ) {
        cancelDocumentMarkCopy()
        let preferences = findWindow?.markPreferences ?? searchSettingsState.marking
        let authority = SearchDocumentAuthority(document)
        let snapshot = document.buffer.markSnapshot
        let originalBookmarks = preferences.bookmarkLines ? document.buffer.bookmarks : nil
        let scope: ResolvedSearchScope
        do {
            scope = try SearchScope.resolve(
                action: "mark",
                snapshot: snapshot.document,
                options: options,
                selections: document.buffer.selections
            )
        }
        catch {
            markFeedback(error.localizedDescription)
            return
        }
        markFeedback("正在查找并准备颜色标记。")
        markSearchGeneration = generation
        searchTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.markSearchGeneration == generation {
                    self.markSearchGeneration = nil
                }
                if self.queryGeneration == generation {
                    self.searchTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let result = try SearchEngine.find(
                        in: snapshot.document,
                        options: scope.options,
                        scope: scope.range,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                    let ranges = result.hits.compactMap(\.range)
                    let marks = try PreparedDocumentMarks(
                        snapshot: snapshot,
                        ranges: ranges,
                        style: .search,
                        append: !preferences.clearPrevious,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                    let bookmarks = try originalBookmarks.map {
                        try SearchEngine.bookmarkPlan(result, snapshot: snapshot.document, existing: $0)
                    }
                    return (marks, bookmarks, result.hits.count, result.hits.count - ranges.count)
                }
                let (marks, bookmarks, count, unmapped) = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 颜色、正文和输入是同一次计划的共同证据，清除或改写后不能用旧完整集合覆盖新状态。
                guard !Task.isCancelled, !self.closing, self.queryGeneration == generation,
                    input.matches(self.findWindow), self.findWindow?.isEditingInput != true,
                    self.mainWindow?.hasMarkedEditorInput != true,
                    self.findWindow == nil || self.findWindow?.options == options,
                    let current = authority.document,
                    self.documents.contains(where: {
                        $0 === current
                    }),
                    authority.matches(current), !current.buffer.isEditingSuspended,
                    current.buffer.markGeneration == snapshot.generation,
                    originalBookmarks == nil || current.buffer.bookmarks == originalBookmarks
                else {
                    if !self.closing, self.queryGeneration == generation, input.matches(self.findWindow) {
                        self.markFeedback("正文、书签或颜色标记已改变，未发布旧标记。")
                    }
                    return
                }
                // 所有可失败的身份门禁已成立，先发布颜色再同步书签，二者之间不跨越可重入边界。
                let retained = try current.buffer.commitMarks(marks)
                if let bookmarks {
                    current.buffer.bookmarks = bookmarks.lines
                }
                self.mainWindow?.refreshEditors()
                self.refreshUI()
                self.markFeedback(
                    "匹配 \(count) 处 · 保留 \(retained) 个查找标记。"
                        + (unmapped > 0 ? "\(unmapped) 个 UTF-16 命中无法无损标记。" : "")
                        + (preferences.bookmarkLines ? "已添加匹配行书签。" : "")
                )
            }
            catch {
                if !self.closing, self.queryGeneration == generation, input.matches(self.findWindow) {
                    self.markFeedback(
                        error is CancellationError || Task.isCancelled
                            ? "标记已取消，已有颜色和书签保留。" : error.localizedDescription
                    )
                }
            }
        }
    }

    /// 业务作用：清除仅回收当前文档的查找颜色，五组样式、书签、结果历史与正文保持独立。
    /// 参数说明: 无。
    /// 返回：旧标记计划失权，实际颜色清除数进入反馈，不增加正文撤销项。
    func clearSearchMarks() {
        guard let context = currentMarkEditor(modifying: true) else {
            return
        }
        cancelDocumentMarkCopy()
        cancelSearchMarking()
        let count = context.document.buffer.clearMarks(.search)
        mainWindow?.refreshEditors()
        refreshUI()
        markFeedback("已清除 \(count) 个查找标记，书签和其他样式保留。")
    }

    /// 业务作用：颜色清除或正文变化只撤销当前标记计划，不取消独立的目录查询或其它搜索结果任务。
    /// 参数说明: 无。
    /// 返回：仍为当前标记请求时先失效身份再取消计算，旧反馈不能盖过新的清除动作。
    func cancelSearchMarking() {
        guard markSearchGeneration == queryGeneration else {
            return
        }
        // 当前计划的所有发布权先失效，再通知后台取消；标记状态本身由调用者明确更新。
        queryGeneration = UUID()
        markSearchGeneration = nil
        searchTask?.cancel()
        searchTask = nil
        if !closing {
            markFeedback("标记已取消，已有颜色和书签保留。")
        }
    }

    /// 业务作用：标记操作在当前查找面板或状态栏反馈，不把标记计数变成工具输出或正文。
    /// 参数说明:
    /// - message: 属于当前有效标记动作的完整说明。
    /// 返回：有查找窗口时更新其反馈，否则更新当前编辑窗口状态。
    func markFeedback(_ message: String) {
        if let findWindow {
            findWindow.feedback.stringValue = message
        }
        else {
            mainWindow?.status.stringValue = message
        }
    }
}
