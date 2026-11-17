import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage

extension ApplicationController {
    /// 业务作用：目录搜索优先使用已打开快照，文件替换先预览并保留原字节副本。
    /// 参数说明:
    /// - directory: 用户填写的搜索根。
    /// - filters: 包含、排除和目录排除模式。
    /// - options: 搜索与替换条件。
    /// - replacing: 是否在确认后修改文件。
    /// 返回：逐文件真实结果，取消后已完成清单仍保留。
    func searchDirectory(_ directory: String, filters: String, options: SearchOptions, replacing: Bool) {
        let requested = options
        var normalized = options
        normalized.selectionOnly = false
        normalized.backwards = false
        normalized.wrap = true
        let options = normalized
        guard !directory.isEmpty else {
            findWindow?.feedback.stringValue = "请先填写明确的搜索目录。"
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let generation = queryGeneration
        let authorities = Dictionary(
            uniqueKeysWithValues: documents.map {
                document in
                (document.buffer.id, SearchDocumentAuthority(document))
            }
        )
        let opened: [String: DocumentSnapshot] = Dictionary(
            uniqueKeysWithValues: documents.compactMap {
                guard let url = $0.url else {
                    return nil
                }
                return (url.resolvingSymlinksInPath().path, $0.buffer.snapshot)
            }
        )
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
                let (plans, failures) = try await reader.readCancellable {
                    token in
                    let matcher = FileFilters(filters)
                    _ = try SearchEngine.find(
                        in: DocumentSnapshot(id: UUID(), revision: 0, text: PieceTree()),
                        options: options,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let listing = try DirectoryTraversal.listing(
                        under: root,
                        limit: 100_000,
                        recursive: options.recursive,
                        includeHidden: options.includeHidden,
                        fileFilter: {
                            matcher.accepts($0)
                        },
                        directoryFilter: {
                            matcher.acceptsDirectory($0, depth: $1)
                        },
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let all = listing.files
                    var failures = listing.failures
                    var plans: [DirectoryPlan] = []
                    var identities: Set<String> = []
                    for url in all where matcher.accepts(url.lastPathComponent) {
                        try token.check()
                        let relative = url.path.dropFirst(root.path.count).split(separator: "/").dropLast()
                        if relative.enumerated().contains(where: {
                            !matcher.acceptsDirectory(String($0.element), depth: $0.offset)
                        }) {
                            continue
                        }
                        do {
                            let loaded = try self.fileAccess.load(
                                url,
                                catalog: catalog,
                                permit: {
                                    !token.isCancelled
                                }
                            )
                            let identity = "\(loaded.baseline.device):\(loaded.baseline.inode)"
                            if !identities.insert(identity).inserted {
                                continue
                            }
                            let snapshot =
                                ((!options.ignoreOpenBuffers || replacing)
                                    ? opened[loaded.baseline.resolvedPath] : nil)
                                ?? DocumentSnapshot(id: UUID(), revision: 0, text: loaded.tree)
                            let result = try SearchEngine.find(
                                in: snapshot,
                                options: options,
                                permit: {
                                    !token.isCancelled
                                }
                            )
                            if !result.hits.isEmpty {
                                let edits =
                                    replacing
                                    ? try SearchEngine.replacementPlan(
                                        result,
                                        snapshot: snapshot,
                                        permit: {
                                            !token.isCancelled
                                        }
                                    ) : []
                                let prepared =
                                    replacing && opened[loaded.baseline.resolvedPath] != nil
                                    ? try PreparedTransaction(snapshot: snapshot, edits: edits, name: "文件中替换")
                                    : nil
                                plans.append(
                                    DirectoryPlan(
                                        url: url,
                                        loaded: loaded,
                                        snapshot: snapshot,
                                        result: result,
                                        edits: edits,
                                        prepared: prepared
                                    )
                                )
                            }
                        }
                        catch {
                            if error is CancellationError {
                                throw error
                            }
                            failures.append(url.path + "：" + error.localizedDescription)
                            guard failures.count <= 10_000 else {
                                throw NateError.message("未读取文件超过 10000 项，请缩小范围。")
                            }
                        }
                    }
                    return (plans, failures)
                }
                try Task.checkCancellation()
                guard !self.closing, generation == self.queryGeneration else {
                    return
                }
                guard self.findWindow?.options == requested else {
                    self.findWindow?.feedback.stringValue = "条件已改变，旧计划未发布。"
                    return
                }
                var output: [String] = []
                var navigation: [ResultNavigation] = []
                var completedFiles = 0
                var completedHits = 0
                var unconfirmedFiles = 0
                if replacing {
                    let alert = NSAlert()
                    alert.messageText = "文件中替换：\(plans.count) 个文件"
                    alert.informativeText =
                        "共 \(plans.reduce(0) { $0 + $1.result.hits.count }) 处。已打开文件修改缓冲区且可撤销；未打开文件直接写盘并先保存 .nate-backup 副本。"
                    alert.addButton(withTitle: "执行替换")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        self.findWindow?.feedback.stringValue = "已取消，文件未修改。"
                        return
                    }
                }
                for plan in plans {
                    if Task.isCancelled || self.closing || generation != self.queryGeneration {
                        output.append("已取消；以上为已完成清单。")
                        break
                    }
                    if replacing {
                        do {
                            if let original = opened[plan.loaded.baseline.resolvedPath] {
                                // 原计划属于打开缓冲区时，关闭、重新打开或改绑都不能降级成直接覆盖磁盘。
                                guard
                                    let document = self.documents.first(where: {
                                        candidate in
                                        candidate.buffer.id == original.id
                                    }),
                                    authorities[original.id]?.matches(document, requireTarget: true) == true,
                                    !self.closing
                                else {
                                    throw NateError.message("原缓冲区已关闭、改变或重新绑定，请重新生成替换计划。")
                                }
                                if let prepared = plan.prepared {
                                    try document.buffer.commit(prepared)
                                }
                                document.dirtyHint = true
                            }
                            else {
                                // 计划后新打开的文件不能沿用旧的关闭文件写入通道。
                                guard
                                    !self.documents.contains(where: {
                                        $0.baseline?.resolvedPath == plan.loaded.baseline.resolvedPath
                                    })
                                else {
                                    throw NateError.message("该文件在计划后已打开，请重新执行以修改当前缓冲区。")
                                }
                                let owner = UUID()
                                guard self.reserveTarget(plan.loaded.baseline.resolvedPath, owner: owner)
                                else {
                                    throw NateError.message("目标正在执行其他文件动作。")
                                }
                                defer {
                                    self.releaseTarget(plan.loaded.baseline.resolvedPath, owner: owner)
                                }
                                try await executor.runCancellable {
                                    token in
                                    var tree = plan.snapshot.text
                                    for edit in plan.edits.reversed() {
                                        tree = try tree.replacing(edit.range, with: edit.text)
                                    }
                                    let data = try plan.loaded.encoding.encode(tree.text(), catalog: catalog)
                                    try token.check()
                                    let backup = plan.url.deletingLastPathComponent().appendingPathComponent(
                                        plan.url.lastPathComponent + "." + UUID().uuidString + ".nate-backup"
                                    )
                                    // 原字节副本先完成持久化，当前目标才可取得自己的单次发布权。
                                    try token.withChild {
                                        request in
                                        _ = try self.fileOperations.save(
                                            using: self.fileAccess,
                                            plan.loaded.originalBytes,
                                            to: backup,
                                            expected: nil,
                                            permit: {
                                                !request.isCancelled
                                            },
                                            authority: request
                                        )
                                    }
                                    try token.withChild {
                                        request in
                                        _ = try self.fileOperations.save(
                                            using: self.fileAccess,
                                            data,
                                            to: plan.url,
                                            expected: plan.loaded.baseline,
                                            permit: {
                                                !request.isCancelled
                                            },
                                            authority: request
                                        )
                                    }
                                }
                            }
                            output.append("成功 · \(plan.url.path) · \(plan.result.hits.count) 处")
                            completedFiles += 1
                            completedHits += plan.result.hits.count
                        }
                        catch {
                            output.append("失败 · \(plan.url.path) · \(error.localizedDescription)")
                            unconfirmedFiles += 1
                        }
                    }
                    else {
                        let fromDisk =
                            options.ignoreOpenBuffers || opened[plan.loaded.baseline.resolvedPath] == nil
                        for hit in plan.result.hits {
                            guard let range = hit.range else {
                                continue
                            }
                            let line = plan.snapshot.text.lineNumber(at: range.lower)
                            output.append(
                                "\(plan.url.path):\(line + 1)  \(plan.snapshot.text.text(in: plan.snapshot.text.lineRange(line, includeEnding: false)).prefix(500))"
                            )
                            navigation.append(
                                ResultNavigation(
                                    documentID: fromDisk
                                        ? nil : opened[plan.loaded.baseline.resolvedPath]?.id,
                                    revision: fromDisk
                                        ? nil : opened[plan.loaded.baseline.resolvedPath]?.revision,
                                    url: plan.url,
                                    range: range,
                                    diskBaseline: fromDisk ? plan.loaded.baseline : nil,
                                    diskEncoding: fromDisk ? plan.loaded.encoding : nil,
                                    authority: fromDisk ? nil : authorities[plan.snapshot.id]
                                )
                            )
                        }
                    }
                }
                // 新查询已经接管结果区域；旧请求的实际文件阶段仍保存在文件任务中，不能覆盖新查询的界面。
                guard generation == self.queryGeneration else {
                    return
                }
                self.resultNavigation = navigation
                output.append(
                    contentsOf: failures.map {
                        "跳过 · " + $0
                    }
                )
                self.mainWindow?.showResults(output.joined(separator: "\n"), navigable: !replacing)
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
                        : "完成 · \(plans.count) 个命中文件，\(plans.reduce(0) { $0 + $1.result.hits.count }) 处。"
                }
                self.mainWindow?.editor.refresh()
                self.refreshUI()
            }
            catch {
                if generation == self.queryGeneration {
                    self.findWindow?.feedback.stringValue =
                        error is CancellationError
                        ? "已取消，未发布新的替换计划。" : error.localizedDescription
                }
            }
        }
    }
}

struct DirectoryPlan: Sendable {
    var url: URL
    var loaded: LoadedFile
    var snapshot: DocumentSnapshot
    var result: SearchResult
    var edits: [TextEdit]
    var prepared: PreparedTransaction?
}
