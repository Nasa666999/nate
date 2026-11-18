import AppKit
import NateCore
import NateSearch
import NateUI

struct IncrementalHighlightKey: Equatable {
    let document: ObjectIdentifier
    let editor: ObjectIdentifier
    let revision: UInt64
    let input: UUID
    let options: IncrementalSearchOptions
}

@MainActor
final class IncrementalHighlightRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?
    var key: IncrementalHighlightKey?
    weak var editor: EditorView?

    /// 业务作用：全部命中高亮与单个命中导航使用独立任务，导航失败或边界不撤销完整高亮。
    /// 参数说明: 无。
    /// 返回：无旧文档、视图或高亮任务的初始状态。
    init() {}
}

enum IncrementalHighlightPlan {
    /// 业务作用：全文字面匹配与临时索引构建共用取消及五秒预算，超限不将部分命中冒充全部高亮。
    /// 参数说明:
    /// - snapshot: 需要匹配的不可变正文。
    /// - query: 已确认的完整增量输入，不解释转义或正则。
    /// - options: 增量栏自己的匹配选项。
    /// - permit: 当前后台请求仍有效的权限。
    /// 返回：十万项以内的完整索引及不可无损定位数量，失败不返回部分索引。
    static func prepare(
        snapshot: DocumentSnapshot,
        query: String,
        options: IncrementalSearchOptions,
        permit: @escaping @Sendable () -> Bool
    ) throws -> (highlights: PreparedTextHighlights, unmapped: Int) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && ContinuousClock.now < deadline
        }
        do {
            let result = try SearchEngine.find(
                in: snapshot,
                options: options.searchOptions(query: query),
                permit: allowed
            )
            let ranges = result.hits.compactMap(\.range)
            let highlights = try PreparedTextHighlights(snapshot: snapshot, ranges: ranges, permit: allowed)
            return (highlights, result.hits.count - ranges.count)
        }
        catch {
            if permit(), !Task.isCancelled, ContinuousClock.now >= deadline {
                throw NateError.message("全部高亮超过五秒，未显示部分结果；单个匹配导航仍可使用。")
            }
            throw error
        }
    }
}

extension ApplicationController {
    /// 业务作用：正文编辑与克隆焦点变化只刷新当前可见增量栏的临时图层，不启动单个命中导航。
    /// 参数说明: 无。
    /// 返回：实际正文与已确认查询重新匹配，栏已关闭时撤销原图层和后台任务。
    func refreshVisibleIncrementalHighlights() {
        guard let window = mainWindow, window.isIncrementalSearchVisible else {
            cancelIncrementalHighlights()
            return
        }
        refreshIncrementalHighlights(
            window.incrementalSearch.query,
            options: window.incrementalSearch.options
        )
    }

    /// 业务作用：清除原视图的增量图层并撤销迟到全文匹配，不影响文档持久标记与其它临时图层。
    /// 参数说明: 无。
    /// 返回：原高亮任务先失权再取消，原视图不再显示旧查询的全部命中。
    func cancelIncrementalHighlights() {
        incrementalHighlights.generation = UUID()
        incrementalHighlights.task?.cancel()
        incrementalHighlights.task = nil
        incrementalHighlights.key = nil
        incrementalHighlights.editor?.setTextHighlights(nil, for: .incremental)
        incrementalHighlights.editor = nil
        if let window = mainWindow, window.isIncrementalSearchVisible {
            window.incrementalSearch.highlightFeedback.stringValue =
                window.incrementalSearch.options.highlightAll ? "全部高亮已暂停。" : "全部高亮已关闭。"
        }
    }

    /// 业务作用：按当前已确认输入独立刷新全部命中，复用同条件完整索引，不接管光标、焦点或查询历史。
    /// 参数说明:
    /// - query: 当前增量栏已经发布的完整输入。
    /// - options: 对应的完整独立选项。
    /// 返回：合法来源启动后台临时高亮，关闭开关立即清除；来源失效、超限和取消不显示部分结果。
    func refreshIncrementalHighlights(_ query: String, options: IncrementalSearchOptions) {
        guard options.highlightAll else {
            cancelIncrementalHighlights()
            return
        }
        guard !closing, let window = mainWindow, window.isIncrementalSearchVisible,
            let document = active, !document.closing,
            documents.contains(where: {
                $0 === document
            }),
            window.editor.document === document.buffer, !document.buffer.isEditingSuspended,
            !window.hasMarkedEditorInput, !window.incrementalSearch.isEditingInput,
            window.incrementalSearch.query.utf8.elementsEqual(query.utf8),
            window.incrementalSearch.input.stringValue.utf8.elementsEqual(query.utf8),
            window.incrementalSearch.options == options, !query.isEmpty
        else {
            cancelIncrementalHighlights()
            return
        }
        let bar = window.incrementalSearch
        let key = IncrementalHighlightKey(
            document: ObjectIdentifier(document.buffer),
            editor: ObjectIdentifier(window.editor),
            revision: document.buffer.revision,
            input: bar.input.contentIdentity,
            options: options
        )
        if incrementalHighlights.key == key {
            return
        }
        cancelIncrementalHighlights()
        incrementalHighlights.key = key
        incrementalHighlights.editor = window.editor
        let generation = incrementalHighlights.generation
        let snapshot = document.buffer.snapshot
        let authority = SearchDocumentAuthority(document)
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor = window.editor] in
            // 全部命中不依赖光标，但必须仍属于同一真实视图、正文和完整输入身份；往返改变也不能复活旧结果。
            guard let self, let window, !self.closing, !Task.isCancelled,
                self.incrementalHighlights.generation == generation, self.mainWindow === window,
                window.isIncrementalSearchVisible, window.editor === editor,
                !window.hasMarkedEditorInput, !bar.isEditingInput,
                bar.input.contentIdentity == key.input, bar.options == options,
                bar.query.utf8.elementsEqual(query.utf8),
                bar.input.stringValue.utf8.elementsEqual(query.utf8),
                let source = authority.document, self.active === source,
                self.documents.contains(where: {
                    $0 === source
                }), authority.matches(source),
                editor?.document === source.buffer, !source.buffer.isEditingSuspended
            else {
                return false
            }
            return true
        }
        bar.highlightFeedback.stringValue = "正在生成全部高亮…"
        incrementalHighlights.task = Task {
            [weak self] in
            guard let self else {
                return
            }
            var published = false
            defer {
                if self.incrementalHighlights.generation == generation {
                    self.incrementalHighlights.task = nil
                    if !published {
                        self.incrementalHighlights.key = nil
                        if bar.highlightFeedback.stringValue == "正在生成全部高亮…" {
                            bar.highlightFeedback.stringValue = "来源或输入已改变，未发布旧高亮。"
                        }
                    }
                }
            }
            do {
                // 连续输入仅计算最后一次完整查询，等待期间仍可取消，不占用主执行域扫描正文。
                try await Task.sleep(for: .milliseconds(80))
                guard current() else {
                    return
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try IncrementalHighlightPlan.prepare(
                        snapshot: snapshot,
                        query: query,
                        options: options,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                guard current(), let editor = self.incrementalHighlights.editor else {
                    if self.incrementalHighlights.generation == generation {
                        self.incrementalHighlights.key = nil
                        bar.highlightFeedback.stringValue = "来源或输入已改变，未发布旧高亮。"
                    }
                    return
                }
                guard editor.setTextHighlights(result.highlights, for: .incremental) else {
                    throw NateError.staleRevision
                }
                published = true
                bar.highlightFeedback.stringValue =
                    "已高亮 \(editor.textHighlightRanges(for: .incremental).count) 处。"
                    + (result.unmapped > 0 ? "\(result.unmapped) 处无法无损定位。" : "")
            }
            catch {
                if self.incrementalHighlights.generation == generation {
                    self.incrementalHighlights.key = nil
                    if current() {
                        bar.highlightFeedback.stringValue =
                            error is CancellationError ? "全部高亮已取消。" : error.localizedDescription
                    }
                }
            }
        }
    }
}
