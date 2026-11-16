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
        guard !directory.isEmpty else {
            findWindow?.feedback.stringValue = "请先填写明确的搜索目录。"
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let generation = queryGeneration
        let opened: [String: DocumentSnapshot] = Dictionary(
            uniqueKeysWithValues: documents.compactMap {
                guard let url = $0.url else {
                    return nil
                }
                return (url.resolvingSymlinksInPath().path, $0.buffer.snapshot)
            }
        )
        let executor = fileIO
        searchTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            do {
                let plans = try await executor.run {
                    let matcher = FileFilters(filters)
                    let all = try DirectoryTraversal.files(under: root, filter: filters, limit: 100_000)
                    var plans: [DirectoryPlan] = []
                    var identities: Set<String> = []
                    for url in all where matcher.accepts(url.lastPathComponent) {
                        try Task.checkCancellation()
                        let relative = url.path.dropFirst(root.path.count).split(separator: "/").dropLast()
                        if relative.enumerated().contains(where: {
                            !matcher.acceptsDirectory(String($0.element), depth: $0.offset)
                        }) {
                            continue
                        }
                        do {
                            let loaded = try FileStorage.load(url)
                            let identity = "\(loaded.baseline.device):\(loaded.baseline.inode)"
                            if !identities.insert(identity).inserted {
                                continue
                            }
                            let snapshot =
                                opened[loaded.baseline.resolvedPath]
                                ?? DocumentSnapshot(id: UUID(), revision: 0, text: PieceTree(loaded.text))
                            let result = try SearchEngine.find(in: snapshot, options: options)
                            if !result.hits.isEmpty {
                                plans.append(
                                    DirectoryPlan(
                                        url: url,
                                        loaded: loaded,
                                        snapshot: snapshot,
                                        result: result,
                                        edits: replacing
                                            ? try SearchEngine.replacementPlan(result, snapshot: snapshot)
                                            : []
                                    )
                                )
                            }
                        }
                        catch {
                            if error is CancellationError {
                                throw error
                            }
                        }
                    }
                    return plans
                }
                guard generation == self.queryGeneration else {
                    return
                }
                var output: [String] = []
                var navigation: [ResultNavigation] = []
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
                    if Task.isCancelled {
                        output.append("已取消；以上为已完成清单。")
                        break
                    }
                    if replacing {
                        do {
                            if let document = self.documents.first(where: {
                                $0.buffer.id == plan.snapshot.id
                            }
                            ) {
                                try document.buffer.commit(
                                    plan.edits,
                                    expectedRevision: plan.snapshot.revision,
                                    name: "文件中替换"
                                )
                                document.dirtyHint = true
                            }
                            else {
                                try await executor.run {
                                    var tree = plan.snapshot.text
                                    for edit in plan.edits.reversed() {
                                        tree = try tree.replacing(edit.range, with: edit.text)
                                    }
                                    let data = try plan.loaded.encoding.encode(tree.text())
                                    let backup = plan.url.deletingLastPathComponent().appendingPathComponent(
                                        plan.url.lastPathComponent + "." + UUID().uuidString + ".nate-backup"
                                    )
                                    _ = try FileStorage.save(
                                        plan.loaded.originalBytes,
                                        to: backup,
                                        expected: nil
                                    )
                                    _ = try FileStorage.save(
                                        data,
                                        to: plan.url,
                                        expected: plan.loaded.baseline
                                    )
                                }
                            }
                            output.append("成功 · \(plan.url.path) · \(plan.result.hits.count) 处")
                        }
                        catch {
                            output.append("失败 · \(plan.url.path) · \(error.localizedDescription)")
                        }
                    }
                    else {
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
                                    documentID: opened[plan.loaded.baseline.resolvedPath]?.id,
                                    revision: opened[plan.loaded.baseline.resolvedPath]?.revision,
                                    url: plan.url,
                                    range: range
                                )
                            )
                        }
                    }
                }
                self.resultNavigation = navigation
                self.mainWindow?.showResults(output.joined(separator: "\n"))
                self.findWindow?.feedback.stringValue =
                    "完成 · \(plans.count) 个命中文件，\(plans.reduce(0) { $0 + $1.result.hits.count }) 处。"
                self.mainWindow?.editor.refresh()
                self.refreshUI()
            }
            catch {
                self.findWindow?.feedback.stringValue = error.localizedDescription
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
}
