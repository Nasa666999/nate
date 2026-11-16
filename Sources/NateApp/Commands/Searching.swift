import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateUI

extension ApplicationController {
    /// 业务作用：查找窗口与正文并行使用，选区填入和范围限制分别处理。
    /// 参数说明:
    /// - replacing: 是否进入替换流程。
    /// 返回：复用查找条件，保持既有历史。
    func presentFind(replacing: Bool) {
        mainWindow?.editor.finishComposition()
        if findWindow == nil {
            let window = FindReplaceWindow()
            window.onAction = {
                [weak self] action, options, directory, filters in
                self?.search(action, options: options, directory: directory, filters: filters)
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
        let selection = active?.buffer.selections.first.flatMap {
            range in
            range.range.count <= 4096 ? active?.buffer.text.text(in: range.range) : nil
        }
        findWindow?.present(selection: selection, replacing: replacing)
    }

    /// 业务作用：固定请求身份、快照和范围，在后台搜索完成后复验再发布。
    /// 参数说明:
    /// - action: 明确的查找或替换范围。
    /// - options: 当前完整搜索状态。
    /// - directory: 跨文件根路径。
    /// - filters: 兼容文件过滤语法。
    /// 返回：匹配、原子替换或明确错误，不允许旧结果更新新查询。
    func search(_ action: String, options: SearchOptions, directory: String, filters: String) {
        searchTask?.cancel()
        queryGeneration = UUID()
        let generation = queryGeneration
        if action == "cancel" {
            findWindow?.feedback.stringValue = "已取消搜索。"
            return
        }
        if action == "files" || action == "replaceFiles" {
            searchDirectory(
                directory,
                filters: filters,
                options: options,
                replacing: action == "replaceFiles"
            )
            return
        }
        mainWindow?.editor.finishComposition()
        guard let active else {
            return
        }
        if options.mode == .regex && (action == "previous" || options.backwards) {
            findWindow?.feedback.stringValue = "正则默认禁用反向搜索；请使用正向匹配导航。"
            return
        }
        if action == "replaceOpen", findWindow?.confirmsOpenReplacement == true {
            let alert = NSAlert()
            alert.messageText = "替换全部打开文档"
            alert.informativeText = "将处理 \(documents.count) 个缓冲区；每个文档可独立撤销，可写文件将自动保存。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        let targets = ["open", "replaceOpen"].contains(action) ? documents : [active]
        let captured = targets.map {
            document in
            (document.buffer.snapshot, options.selectionOnly ? document.buffer.selections.first?.range : nil)
        }
        let startingSelection = active.buffer.selections.first?.range ?? ByteRange(0, 0)
        let activeID = active.buffer.id
        searchTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try captured.map {
                        snapshot,
                        scope in
                        try Task.checkCancellation()
                        let result = try SearchEngine.find(in: snapshot, options: options, scope: scope)
                        let edits =
                            action.hasPrefix("replace")
                            ? try SearchEngine.replacementPlan(result, snapshot: snapshot) : []
                        return (snapshot, result, edits)
                    }
                }
                let batches = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                guard generation == self.queryGeneration else {
                    return
                }
                var count = 0
                var skipped = 0
                var output: [String] = []
                var navigation: [ResultNavigation] = []
                for (snapshot, result, edits) in batches {
                    guard
                        let document = self.documents.first(where: {
                            $0.buffer.id == snapshot.id
                        }),
                        document.buffer.revision == snapshot.revision
                    else {
                        throw NateError.staleRevision
                    }
                    if action == "replaceAll" || action == "replaceOpen" {
                        if document.buffer.isReadOnly {
                            skipped += 1
                            continue
                        }
                        try document.buffer.commit(edits, expectedRevision: snapshot.revision, name: "全部替换")
                        document.dirtyHint = !edits.isEmpty || document.dirtyHint
                        count += result.hits.count
                    }
                    else if action == "replaceOne" {
                        guard document.buffer.id == activeID else {
                            continue
                        }
                        guard
                            let index = result.hits.firstIndex(where: {
                                $0.range == startingSelection
                            })
                        else {
                            self.findWindow?.feedback.stringValue = "当前选区不是该条件的完整匹配，请先查找。"
                            return
                        }
                        try document.buffer.commit(
                            [edits[index]],
                            expectedRevision: snapshot.revision,
                            name: "替换一个"
                        )
                        document.dirtyHint = true
                        count = 1
                    }
                    else if ["next", "previous"].contains(action) {
                        let previous = action == "previous" || options.backwards
                        let candidates = result.hits.filter {
                            hit in
                            guard let range = hit.range else {
                                return false
                            }
                            return previous
                                ? range.upper <= startingSelection.lower && range != startingSelection
                                : range.lower >= startingSelection.upper && range != startingSelection
                        }
                        let hit =
                            previous
                            ? candidates.last ?? (options.wrap ? result.hits.last : nil)
                            : candidates.first ?? (options.wrap ? result.hits.first : nil)
                        if let range = hit?.range {
                            document.buffer.selections = [
                                TextSelection(anchor: range.lower, head: range.upper)
                            ]
                            self.mainWindow?.editor.refresh(reveal: true)
                            self.findWindow?.feedback.stringValue = "共 \(result.hits.count) 个匹配，已定位当前匹配。"
                        }
                        else {
                            self.findWindow?.feedback.stringValue = "已到达边界或没有匹配。"
                        }
                        self.refreshUI()
                        return
                    }
                    else if action == "mark" {
                        for hit in result.hits {
                            guard let range = hit.range else {
                                continue
                            }
                            let a = snapshot.text.lineNumber(at: range.lower)
                            let b = snapshot.text.lineNumber(at: max(range.lower, range.upper - 1))
                            document.buffer.bookmarks.formUnion(a...b)
                        }
                        count += result.hits.count
                    }
                    else {
                        count += result.hits.count
                        if action != "count" {
                            for hit in result.hits {
                                guard let range = hit.range else {
                                    continue
                                }
                                let line = snapshot.text.lineNumber(at: range.lower)
                                output.append(
                                    "\(document.url?.path ?? document.name):\(line + 1)  \(snapshot.text.text(in: snapshot.text.lineRange(line, includeEnding: false)).prefix(500))"
                                )
                                navigation.append(
                                    ResultNavigation(
                                        documentID: document.buffer.id,
                                        revision: snapshot.revision,
                                        url: document.url,
                                        range: range
                                    )
                                )
                            }
                        }
                    }
                }
                self.findWindow?.feedback.stringValue =
                    "\(action.hasPrefix("replace") ? "替换" : "匹配") \(count) 处。\(skipped > 0 ? "跳过 \(skipped) 个只读文档。" : "")"
                if !output.isEmpty {
                    self.resultNavigation = navigation
                    self.mainWindow?.showResults(output.joined(separator: "\n"))
                }
                self.mainWindow?.editor.refresh()
                self.refreshUI()
            }
            catch is CancellationError {
                if generation == self.queryGeneration {
                    self.findWindow?.feedback.stringValue = "已取消，未发布搜索计划。"
                }
            }
            catch {
                if generation == self.queryGeneration {
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
}
