import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：正文候选、搜索原文或配置改变时撤销既有请求，往返修改不能恢复旧结果的选择或写入权限。
    /// 参数说明: 无。
    /// 返回：请求身份先失效，再取消计算并收回句柄；正文、查询原文和历史不变。
    func suspendSearchForInput() {
        cancelSearchResultExport()
        cancelSearchResultPathOpen()
        let hadSearch = searchTask != nil
        projectSearchScope = nil
        directoryWorkspace?.cancelOpen()
        cancelProjectOpen()
        // 先撤销发布资格再通知底层取消，已完成但仍等待主执行域的旧结果也必须失效。
        cancelIncrementalSearch(resetOrigin: true)
        queryGeneration = UUID()
        searchNavigationGeneration = UUID()
        resultNavigationGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        searchNavigationEvidence = nil
        cancelCompletion()
        if hadSearch {
            findWindow?.feedback.stringValue = "输入状态已改变，请确认当前条件后重新执行。"
        }
    }

    /// 业务作用：查找窗口与正文并行使用，选区填入和范围限制分别处理。
    /// 参数说明:
    /// - replacing: 是否进入替换流程。
    /// - inFiles: 是否显示目录与过滤条件，进入跨文件范围。
    /// - inProjects: 是否显示可用项目面板选择，进入显式文件引用范围。
    /// 返回：复用查找条件，保持既有历史。
    func presentFind(replacing: Bool, inFiles: Bool = false, inProjects: Bool = false) {
        // 查找界面接管新的输入意图，原目录读取不能在随后等待结束时抢回正文焦点。
        directoryWorkspace?.cancelOpen()
        cancelProjectOpen()
        // 完整查找窗口重新接管用户意图，旧增量请求不能在打开窗口后移动正文光标。
        cancelIncrementalSearch()
        // 当前草稿和候选仍由原输入上下文持有，重复快捷键不能改填另一份查询或结束候选。
        guard findWindow?.isEditingInput != true, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        if findWindow == nil {
            let window = FindReplaceWindow()
            do {
                try window.restore(searchSettingsState)
            }
            catch {
                searchSettingsError = error.localizedDescription
            }
            if searchSettingsURL != nil {
                window.onStateChange = {
                    [weak self] state in
                    self?.scheduleSearchSettings(state)
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
        }
        let selection = refreshSearchPresentation(filling: true)
        refreshProjectSearchAvailability()
        findWindow?.present(
            selection: selection,
            page: inProjects ? .projects : inFiles ? .files : replacing ? .replace : .find
        )
        if let searchSettingsError {
            findWindow?.feedback.stringValue = searchSettingsError
        }
        // 原字段结束编辑可能提交最后一次确认输入，完成焦点转交后再封住这类迟到增量请求。
        cancelIncrementalSearch()
        if mainWindow?.isIncrementalSearchVisible == true {
            mainWindow?.incrementalSearch.feedback.stringValue = "已切换到查找窗口。"
        }
    }

    /// 业务作用：固定请求身份、快照和范围，在后台搜索完成后复验再发布。
    /// 参数说明:
    /// - action: 明确的查找或替换范围。
    /// - options: 当前完整搜索状态。
    /// - directory: 跨文件根路径。
    /// - filters: 兼容文件过滤语法。
    /// - afterReplacement: 单次替换后自动导航时保留替换数量反馈。
    /// 返回：匹配、原子替换或明确错误，不允许旧结果更新新查询。
    func search(
        _ action: String,
        options: SearchOptions,
        directory: String,
        filters: String,
        afterReplacement: Bool = false
    ) {
        if action == "clearSearchMarks" || action == "copySearchMarks" {
            guard !closing, findWindow?.isEditingInput != true, mainWindow?.hasMarkedEditorInput != true
            else {
                return
            }
            if action == "clearSearchMarks" {
                clearSearchMarks()
            }
            else {
                copyDocumentMarks(styles: [.search])
            }
            return
        }
        // 明确的完整查找或替换取代增量输入，先撤销旧导航的发布资格。
        cancelIncrementalSearch()
        searchTask?.cancel()
        resultNavigationTask?.cancel()
        if action == "cancel" {
            projectSearchScope = nil
            findWindow?.feedback.stringValue =
                searchTask == nil
                ? "当前没有正在执行的搜索任务。" : "正在取消；已发布的文件修改会保留实际完成清单。"
            return
        }
        // 新请求即使在参数校验时被拒绝，也不能继续把旧的已取消句柄当作当前搜索。
        searchTask = nil
        projectSearchScope = nil
        queryGeneration = UUID()
        let generation = queryGeneration
        // 退出收束已经撤销新的正文发布权，后台搜索入口不能重新授予它。
        guard !closing else {
            return
        }
        // 菜单入口也可能发生在候选或全文草稿中，不能把尚未确认的字段当成执行条件。
        guard findWindow?.isEditingInput != true, mainWindow?.hasMarkedEditorInput != true else {
            findWindow?.feedback.stringValue = "请先确认或取消输入法候选、全文草稿，再执行查找。"
            return
        }
        let input = SearchRequestInput(findWindow)
        if action == "files" || action == "replaceFiles" {
            searchDirectory(
                directory,
                filters: filters,
                options: options,
                replacing: action == "replaceFiles"
            )
            return
        }
        if action == "projects" || action == "replaceProjects" {
            searchProjects(filters: filters, options: options, replacing: action == "replaceProjects")
            return
        }
        guard let active else {
            return
        }
        if action == "highlight" {
            highlightSearchMatches(active, options: options, input: input, generation: generation)
            return
        }
        if options.mode == .regex && (action == "previous" || options.backwards) {
            findWindow?.feedback.stringValue = "正则默认禁用反向搜索；请使用正向匹配导航。"
            return
        }
        if ["next", "previous", "replaceOne"].contains(action) {
            navigateSearch(action, options: options, afterReplacement: afterReplacement)
            return
        }
        if action == "replaceOpen", findWindow?.confirmsOpenReplacement == true {
            let expectedTargets = documents.map {
                SearchDocumentAuthority($0)
            }
            let alert = NSAlert()
            alert.messageText = "替换全部打开文档"
            alert.informativeText = "将处理 \(documents.count) 个缓冲区；每个文档可独立撤销，可写文件将自动保存。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            // 确认窗口运行嵌套事件循环，旧请求不能在新查询接管后重新登记为当前任务。
            guard generation == queryGeneration, !closing else {
                return
            }
            guard choice == .alertFirstButtonReturn else {
                findWindow?.feedback.stringValue = "已取消，未开始替换打开文档。"
                return
            }
            // 用户确认的是提示时的真实文档集合与正文，新增、重开或改写不能沿用这份修改许可。
            guard input.matches(findWindow), expectedTargets.count == documents.count,
                zip(expectedTargets, documents).allSatisfy({
                    authority,
                    document in authority.matches(document)
                })
            else {
                findWindow?.feedback.stringValue = "条件、目标集合或正文已改变，未开始替换，请重新执行。"
                return
            }
        }
        let targets = ["open", "replaceOpen"].contains(action) ? documents : [active]
        let authorities = Dictionary(
            uniqueKeysWithValues: targets.map {
                document in
                (document.buffer.id, SearchDocumentAuthority(document))
            }
        )
        let captured: [BufferSearchCapture]
        do {
            captured = try targets.map {
                document in
                let snapshot = document.buffer.snapshot
                return BufferSearchCapture(
                    snapshot: snapshot,
                    scope: try SearchScope.resolve(
                        action: action,
                        snapshot: snapshot,
                        options: options,
                        selections: document.buffer.selections
                    ),
                    label: document.url?.path ?? document.name,
                    bookmarks: action == "mark" ? document.buffer.bookmarks : nil,
                    bookmarkGeneration: action == "mark" ? document.buffer.bookmarkGeneration : nil
                )
            }
        }
        catch {
            findWindow?.feedback.stringValue = error.localizedDescription
            return
        }
        let actualScope = captured.count == 1 ? captured[0].scope.description : "\(captured.count) 个文档全文 · 正向"
        let displaysResults = !action.hasPrefix("replace") && !["count", "mark"].contains(action)
        searchTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            // 只收回本请求的句柄，迟到完成不能清除新查询仍在使用的取消入口。
            defer {
                if generation == self.queryGeneration {
                    self.searchTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    var preview = SearchResultPreviewBuilder()
                    var unmappedBookmarks = 0
                    let batches = try captured.map {
                        capture in
                        try Task.checkCancellation()
                        let snapshot = capture.snapshot
                        if action == "count" {
                            return BufferSearchPlan(
                                snapshot: snapshot,
                                hitCount: try SearchEngine.count(
                                    in: snapshot,
                                    options: capture.scope.options,
                                    scope: capture.scope.range
                                ),
                                edits: [],
                                transaction: nil,
                                previews: [],
                                originalBookmarks: nil,
                                originalBookmarkGeneration: nil,
                                bookmarkPlan: nil
                            )
                        }
                        let result = try SearchEngine.find(
                            in: snapshot,
                            options: capture.scope.options,
                            scope: capture.scope.range
                        )
                        let edits =
                            action.hasPrefix("replace")
                            ? try SearchEngine.replacementPlan(result, snapshot: snapshot) : []
                        let prepared =
                            ["replaceAll", "replaceOpen"].contains(action)
                            ? try PreparedTransaction(
                                snapshot: snapshot,
                                edits: edits,
                                name: "全部替换"
                            ) : nil
                        let rows =
                            displaysResults
                            ? try preview.prepare(result.hits, text: snapshot.text, label: capture.label) : []
                        let bookmarks = try capture.bookmarks.map {
                            try SearchEngine.bookmarkPlan(result, snapshot: snapshot, existing: $0)
                        }
                        unmappedBookmarks += bookmarks?.unmappedCount ?? 0
                        return BufferSearchPlan(
                            snapshot: snapshot,
                            hitCount: result.hits.count,
                            edits: edits,
                            transaction: prepared,
                            previews: rows,
                            originalBookmarks: capture.bookmarks,
                            originalBookmarkGeneration: capture.bookmarkGeneration,
                            bookmarkPlan: bookmarks
                        )
                    }
                    return (batches, preview.unmappedCount + unmappedBookmarks)
                }
                let (batches, unmapped) = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                try Task.checkCancellation()
                guard !self.closing, generation == self.queryGeneration,
                    self.mainWindow?.hasMarkedEditorInput != true,
                    self.findWindow?.isEditingInput != true,
                    input.matches(self.findWindow), self.findWindow?.options == options
                else {
                    return
                }
                var resolved: [UUID: WorkspaceDocument] = [:]
                // 多文档动作先复验完整集合，再开始同步发布，避免后一个目标失效时前一个已经被改写。
                for plan in batches {
                    let snapshot = plan.snapshot
                    guard
                        let document = self.documents.first(where: {
                            candidate in
                            candidate.buffer.id == snapshot.id
                        }), authorities[snapshot.id]?.matches(document) == true
                    else {
                        throw NateError.staleRevision
                    }
                    // 后台期间手动增删的书签属于更新的用户意图，旧集合不能覆盖它们。
                    if let original = plan.originalBookmarks {
                        guard document.buffer.bookmarks == original,
                            document.buffer.bookmarkGeneration == plan.originalBookmarkGeneration
                        else {
                            throw NateError.message("书签已改变，原标记计划未发布，请重新执行。")
                        }
                    }
                    if action.hasPrefix("replace"), !document.buffer.isReadOnly {
                        guard !document.buffer.isEditingSuspended, document.buffer.revision < UInt64.max
                        else {
                            throw NateError.message("目标文档正在完成保护动作或修订已达到上限，未开始本轮替换。")
                        }
                    }
                    resolved[snapshot.id] = document
                }
                var count = 0
                var skipped = 0
                var files: [SearchResultFilePresentation] = []
                var navigation: [(UUID, ResultNavigation)] = []
                for plan in batches {
                    let snapshot = plan.snapshot
                    guard let document = resolved[snapshot.id] else {
                        throw NateError.staleRevision
                    }
                    if action == "replaceAll" || action == "replaceOpen" {
                        if document.buffer.isReadOnly {
                            skipped += 1
                            continue
                        }
                        if let prepared = plan.transaction {
                            try document.buffer.commit(prepared)
                        }
                        document.dirtyHint = !plan.edits.isEmpty || document.dirtyHint
                        count += plan.hitCount
                    }
                    else if action == "mark" {
                        if let bookmarks = plan.bookmarkPlan {
                            document.buffer.bookmarks = bookmarks.lines
                        }
                        count += plan.hitCount
                    }
                    else {
                        count += plan.hitCount
                        if displaysResults {
                            if plan.hitCount > 0 {
                                files.append(
                                    SearchResultFilePresentation(
                                        id: snapshot.id,
                                        name: document.name,
                                        path: document.url?.path,
                                        matchCount: plan.hitCount,
                                        rows: plan.previews
                                    )
                                )
                            }
                            for row in plan.previews {
                                let destination = ResultNavigation(
                                    documentID: document.buffer.id,
                                    revision: snapshot.revision,
                                    url: document.url,
                                    range: row.range,
                                    authority: authorities[snapshot.id]
                                )
                                navigation.append((row.id, destination))
                            }
                        }
                    }
                }
                self.findWindow?.feedback.stringValue =
                    actualScope + " · "
                    + "\(action.hasPrefix("replace") ? "替换" : "匹配") \(count) 处。\(skipped > 0 ? "跳过 \(skipped) 个只读文档。" : "")"
                    + (unmapped > 0 ? "其中 \(unmapped) 个 UTF-16 命中无法无损定位。" : "")
                if displaysResults {
                    var notes: [String] = []
                    if unmapped > 0 {
                        notes.append("\(unmapped) 个 UTF-16 命中无法无损定位，请调整表达式。")
                    }
                    if files.isEmpty {
                        notes.append("当前查询没有可导航匹配。")
                    }
                    let removed = try self.publishSearchResults(
                        id: generation,
                        query: options.query,
                        scope: actualScope,
                        files: files,
                        notes: notes,
                        destinations: navigation,
                        condition: SearchResultCondition(captured.first?.scope.options ?? options)
                    )
                    if removed > 0 {
                        self.findWindow?.feedback.stringValue += "结果容量已满，已移除 \(removed) 个最旧批次。"
                    }
                }
                self.mainWindow?.refreshEditors()
                self.refreshUI()
            }
            catch is CancellationError {
                // 错误反馈同样属于原查询，不能覆盖用户已经改写的表达式状态。
                if generation == self.queryGeneration, self.findWindow?.isEditingInput != true,
                    self.mainWindow?.hasMarkedEditorInput != true,
                    input.matches(self.findWindow), self.findWindow?.options == options
                {
                    self.findWindow?.feedback.stringValue = "已取消，未发布搜索计划。"
                }
            }
            catch {
                // 表达式失败也必须持有原输入的反馈权，不能覆盖已经改变的查找条件。
                if generation == self.queryGeneration, self.findWindow?.isEditingInput != true,
                    self.mainWindow?.hasMarkedEditorInput != true,
                    input.matches(self.findWindow), self.findWindow?.options == options
                {
                    self.findWindow?.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }
}

struct ResultNavigation {
    var documentID: UUID?
    var revision: UInt64?
    var url: URL?
    var range: ByteRange
    var diskBaseline: NateStorage.DiskBaseline? = nil
    var diskEncoding: NateStorage.TextEncoding? = nil
    var authority: SearchDocumentAuthority? = nil
}
