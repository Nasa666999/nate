import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：目录和项目文件集合共用固定快照、预览、取消与逐文件替换保护。
    /// 参数说明:
    /// - source: 已明确选择的目录或项目文件引用集合。
    /// - filters: 实际文件名的包含与排除条件。
    /// - options: 本次完整搜索与替换条件。
    /// - replacing: 是否在预览确认后执行文件修改。
    /// - current: 当前输入和来源定义是否仍拥有本次发布与后续文件执行权限。
    /// 返回：完整搜索结果或逐文件真实完成清单，失效范围不能继续发布新结果或开始后续文件。
    func searchFiles(
        source: FileSearchSource,
        filters: String,
        options: SearchOptions,
        replacing: Bool,
        current: @escaping @MainActor () -> Bool
    ) {
        var normalized = options
        normalized.selectionOnly = false
        normalized.backwards = false
        normalized.wrap = true
        let options = normalized
        let generation = queryGeneration
        let authorities = Dictionary(
            uniqueKeysWithValues: documents.map {
                document in
                (document.buffer.id, SearchDocumentAuthority(document))
            }
        )
        let opened = documents.compactMap {
            document -> FileSearchBufferSnapshot? in
            guard let url = document.url else {
                return nil
            }
            return FileSearchBufferSnapshot(
                url: url,
                baseline: document.baseline,
                snapshot: document.buffer.snapshot
            )
        }
        let executor = fileIO
        let reader = readIO
        let catalog = codecs
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
                let source = try await self.authorizeFileSearchSource(
                    source,
                    filters: filters,
                    current: current
                )
                // 定义解析和位置确认都可能等待，新条件接管后不能继续把旧集合交给文件读取。
                try Task.checkCancellation()
                guard !self.closing, generation == self.queryGeneration, current() else {
                    return
                }
                let prepared = try await reader.readCancellable {
                    token in
                    try FileSearchPlanning.prepare(
                        source: source,
                        filters: filters,
                        options: options,
                        replacing: replacing,
                        opened: opened,
                        access: self.fileAccess,
                        catalog: catalog,
                        token: token
                    )
                }
                let plans = prepared.plans
                let failures = prepared.failures
                let unmapped = prepared.unmapped
                try Task.checkCancellation()
                guard !self.closing, generation == self.queryGeneration else {
                    return
                }
                // 来源定义和过滤条件同样决定目标集合，后台计划不能在这些证据变化后取得发布权。
                guard
                    self.mainWindow?.hasMarkedEditorInput != true,
                    current()
                else {
                    self.findWindow?.feedback.stringValue = "条件已改变，旧计划未发布。"
                    return
                }
                var output: [String] = []
                var navigation: [(UUID, ResultNavigation)] = []
                var files: [SearchResultFilePresentation] = []
                var completedFiles = 0
                var completedHits = 0
                var unconfirmedFiles = 0
                if replacing && !plans.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = source.replacementTitle + "：\(plans.count) 个文件"
                    alert.informativeText =
                        "共 \(plans.reduce(0) { $0 + $1.hitCount }) 处。已打开文件修改缓冲区且可撤销；未打开文件逐个复验后直接写盘并先保存 .nate-backup 副本。"
                    alert.addButton(withTitle: "执行替换")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        self.findWindow?.feedback.stringValue = "已取消，文件未修改。"
                        return
                    }
                }
                // 确认窗口会运行嵌套事件循环，原查询条件仍须成立才能开始执行固定计划。
                guard
                    self.mainWindow?.hasMarkedEditorInput != true,
                    current()
                else {
                    self.findWindow?.feedback.stringValue = "条件已改变，原计划未执行。"
                    return
                }
                for plan in plans {
                    if Task.isCancelled || self.closing || generation != self.queryGeneration {
                        output.append("已取消；以上为已完成清单。")
                        break
                    }
                    // 文件动作等待期间可以重新编辑条件，后续文件不得继续沿用已经撤销的请求参数。
                    guard
                        self.mainWindow?.hasMarkedEditorInput != true,
                        current()
                    else {
                        output.append("条件已改变；后续文件未开始。")
                        break
                    }
                    if replacing {
                        do {
                            if let documentID = plan.documentID {
                                // 原计划属于打开缓冲区时，关闭、重新打开或改绑都不能降级成直接覆盖磁盘。
                                guard
                                    let document = self.documents.first(where: {
                                        candidate in
                                        candidate.buffer.id == documentID
                                    }),
                                    authorities[documentID]?.matches(document, requireTarget: true) == true,
                                    !self.closing
                                else {
                                    throw NateError.message("原缓冲区已关闭、改变或重新绑定，请重新生成替换计划。")
                                }
                                guard let prepared = plan.prepared else {
                                    throw NateError.message("打开缓冲区缺少完整替换事务，正文未改变。")
                                }
                                if try document.buffer.commit(prepared) {
                                    document.dirtyHint = true
                                }
                            }
                            else {
                                // 计划后新打开的文件和它的硬链接别名都持有同一目标，不能沿用旧的关闭文件写入通道。
                                guard
                                    !self.documents.contains(where: {
                                        $0.baseline?.resolvedPath == plan.baseline.resolvedPath
                                            || ($0.baseline?.device == plan.baseline.device
                                                && $0.baseline?.inode == plan.baseline.inode)
                                    })
                                else {
                                    throw NateError.message("该文件在计划后已打开，请重新执行以修改当前缓冲区。")
                                }
                                let owner = UUID()
                                guard self.reserveTarget(plan.baseline.resolvedPath, owner: owner)
                                else {
                                    throw NateError.message("目标正在执行其他文件动作。")
                                }
                                defer {
                                    self.releaseTarget(plan.baseline.resolvedPath, owner: owner)
                                }
                                try await executor.runCancellable {
                                    token in
                                    try plan.replaceFile(
                                        using: self.fileAccess,
                                        operations: self.fileOperations,
                                        catalog: catalog,
                                        token: token
                                    )
                                }
                            }
                            output.append("成功 · \(plan.url.path) · \(plan.hitCount) 处")
                            completedFiles += 1
                            completedHits += plan.hitCount
                        }
                        catch {
                            output.append("失败 · \(plan.url.path) · \(error.localizedDescription)")
                            unconfirmedFiles += 1
                        }
                    }
                    else {
                        let fromDisk = plan.documentID == nil
                        files.append(
                            SearchResultFilePresentation(
                                id: UUID(),
                                name: plan.url.lastPathComponent,
                                path: plan.url.path,
                                matchCount: plan.hitCount,
                                rows: plan.previews
                            )
                        )
                        for row in plan.previews {
                            let destination = ResultNavigation(
                                documentID: plan.documentID,
                                revision: plan.revision,
                                url: plan.url,
                                range: row.range,
                                diskBaseline: fromDisk ? plan.baseline : nil,
                                diskEncoding: fromDisk ? plan.encoding : nil,
                                authority: plan.documentID.flatMap {
                                    authorities[$0]
                                }
                            )
                            navigation.append((row.id, destination))
                        }
                    }
                }
                // 新查询已经接管结果区域；旧请求的实际文件阶段仍保存在文件任务中，不能覆盖新查询的界面。
                guard generation == self.queryGeneration else {
                    return
                }
                output.append(
                    contentsOf: failures.map {
                        "跳过 · " + $0
                    }
                )
                if output.isEmpty && (replacing || files.isEmpty) {
                    output.append(unmapped > 0 ? "当前查询的 UTF-16 命中无法无损定位，请调整表达式。" : "当前查询没有匹配。")
                }
                var removed = 0
                if replacing {
                    self.mainWindow?.showResults(output.joined(separator: "\n"))
                }
                else {
                    if unmapped > 0 {
                        output.append("\(unmapped) 个 UTF-16 命中无法无损定位，请调整表达式。")
                    }
                    removed = try self.publishSearchResults(
                        id: generation,
                        query: options.query,
                        scope: source.summary,
                        files: files,
                        notes: output,
                        destinations: navigation
                    )
                }
                if replacing {
                    let notStarted = plans.count - completedFiles - unconfirmedFiles
                    self.findWindow?.feedback.stringValue =
                        (Task.isCancelled ? "已取消 · " : "处理结束 · ")
                        + "已确认完成 \(completedFiles) 个文件、\(completedHits) 处；\(unconfirmedFiles) 个文件未确认完成。"
                        + "未开始 \(notStarted) 个文件。"
                        + "逐文件状态及发布后错误见结果与文件任务。"
                }
                else {
                    self.findWindow?.feedback.stringValue =
                        Task.isCancelled
                        ? "已取消；以上为实际完成清单。"
                        : "完成 · \(plans.count) 个命中文件，\(plans.reduce(0) { $0 + $1.hitCount }) 处。"
                    if unmapped > 0 {
                        self.findWindow?.feedback.stringValue += "其中 \(unmapped) 个 UTF-16 命中无法无损定位。"
                    }
                }
                self.findWindow?.feedback.stringValue =
                    source.summary + " · " + (self.findWindow?.feedback.stringValue ?? "")
                    + " 读取成功 \(prepared.readFiles) 个不同文件；\(failures.count) 项未读取。"
                if removed > 0 {
                    self.findWindow?.feedback.stringValue += "结果容量已满，已移除 \(removed) 个最旧批次。"
                }
                self.mainWindow?.editor.refresh()
                self.refreshUI()
            }
            catch {
                // 枚举或编译失败也不能把旧范围的错误发布到新请求上。
                if generation == self.queryGeneration,
                    self.mainWindow?.hasMarkedEditorInput != true,
                    current()
                {
                    self.findWindow?.feedback.stringValue =
                        error is CancellationError
                        ? "已取消，未发布新的替换计划。" : error.localizedDescription
                }
            }
        }
    }
}
