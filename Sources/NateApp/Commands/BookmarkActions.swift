import AppKit
import NateCore
import NateUI

enum BookmarkCommandResult {
    case unavailable
    case completed
    case pending(Task<Bool, Never>)
}

@MainActor
final class BookmarkActionRuntime {
    var generation = UUID()
    var task: Task<Bool, Never>?

    /// 业务作用：书签行任务拥有独立取消身份，不借用正文修订或查找任务身份。
    /// 参数说明: 无。
    /// 返回：尚未启动行任务的运行期状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：新的行意图、正文修改或退出先撤销旧书签任务的发布权，再收回后台任务。
    /// 参数说明: 无。
    /// 返回：迟到计划不能再改变正文、书签与系统剪贴板。
    func cancelBookmarkAction() {
        bookmarkActions.generation = UUID()
        bookmarkActions.task?.cancel()
        bookmarkActions.task = nil
    }

    /// 业务作用：书签导航、元数据和正文动作经明确类型分派，未知标识不能落入删除分支。
    /// 参数说明:
    /// - command: 用户明确选择的稳定书签命令。
    /// 返回：同步动作已完成，或返回可等待的实际发布任务；候选输入、保护或来源失效时不可用。
    @discardableResult
    func bookmarkCommand(_ command: String) -> BookmarkCommandResult {
        if command == "cancelBookmarkAction" {
            cancelBookmarkAction()
            markFeedback("书签行操作已取消。")
            return .completed
        }
        guard let action = BookmarkAction(rawValue: command),
            let context = currentMarkEditor(
                modifying: action != .copy && action != .next && action != .previous
            ),
            documents.contains(where: {
                $0 === context.document
            })
        else {
            return .unavailable
        }
        let buffer = context.document.buffer
        // 行剪切和替换拥有正文副作用，只读时必须在读取剪贴板和安排后台任务前拒绝。
        guard !action.changesText || !buffer.isReadOnly else {
            markFeedback("文档只读，书签行正文保持不变。")
            return .unavailable
        }
        cancelBookmarkAction()
        let recording =
            macroRecording && !macroPlaying && action.macroTitle != nil
            ? macroRecordingGeneration : nil
        let row = buffer.text.lineNumber(at: context.editor.primarySelection?.head ?? 0)
        switch action {
        case .toggle:
            if buffer.bookmarks.contains(row) {
                buffer.bookmarks.remove(row)
            }
            else {
                guard buffer.bookmarks.count < 100_000 else {
                    markFeedback("书签最多保留十万行，已有集合保留。")
                    return .unavailable
                }
                buffer.bookmarks.insert(row)
            }
        case .clear:
            buffer.bookmarks.removeAll()
        case .next, .previous:
            let lines = buffer.bookmarks.sorted()
            let target =
                action == .next
                ? lines.first(where: {
                    $0 > row
                }) ?? lines.first
                : lines.last(where: {
                    $0 < row
                }) ?? lines.last
            if let target {
                // 显式导航接管光标，先撤销尚未完成的查找和外部路径定位意图。
                searchNavigationGeneration = UUID()
                cancelIncrementalSearch(resetOrigin: true)
                cancelSearchResultPathOpen()
                resultNavigationGeneration = UUID()
                context.editor.setCaret(buffer.text.lineStart(target))
                context.editor.refresh(reveal: true)
            }
        default:
            return .pending(
                beginBookmarkAction(
                    action,
                    document: context.document,
                    window: context.window,
                    recording: recording
                )
            )
        }
        recordBookmarkAction(action, generation: recording)
        context.window.refreshEditors()
        refreshUI()
        return .completed
    }

    /// 业务作用：固定真实视图、正文、书签与剪贴板证据，后台只构建未发布的完整行计划。
    /// 参数说明:
    /// - action: 复制、剪切、替换、删除或反转书签集合。
    /// - document: 开始动作时属于工作区的真实文档。
    /// - window: 持有当前编辑视图的窗口。
    /// - recording: 开始时符合条件的宏录制代次。
    /// 返回：可等待的完整发布结果；剪切在剪贴板成功接受完整内容后才删除原文。
    private func beginBookmarkAction(
        _ action: BookmarkAction,
        document: WorkspaceDocument,
        window: EditorWindow,
        recording: UUID?
    ) -> Task<Bool, Never> {
        let authority = SearchDocumentAuthority(document)
        let snapshot = document.buffer.snapshot
        let bookmarks = document.buffer.bookmarks
        let bookmarkGeneration = document.buffer.bookmarkGeneration
        let generation = bookmarkActions.generation
        let input = SearchRequestInput(findWindow)
        let selections = window.editor.viewSelections
        let movement = searchNavigationGeneration
        let clipboard = NSPasteboard.general.changeCount
        let replacement = action == .replace ? NSPasteboard.general.string(forType: .string) : nil
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor = window.editor] in
            // 行范围不能被旧克隆、光标往返、关闭重开或书签往返重新授予发布资格。
            guard let self, let window, !self.closing, !Task.isCancelled,
                self.bookmarkActions.generation == generation, self.mainWindow === window,
                window.editor === editor, !window.hasMarkedEditorInput,
                input.matches(self.findWindow), self.findWindow?.isEditingInput != true,
                self.searchNavigationGeneration == movement, editor?.viewSelections == selections,
                let source = authority.document, self.active === source,
                self.documents.contains(where: {
                    $0 === source
                }), authority.matches(source),
                editor?.document === source.buffer,
                source.buffer.bookmarkGeneration == bookmarkGeneration,
                (!action.changesText || !source.buffer.isReadOnly),
                (action == .copy || !source.buffer.isEditingSuspended)
            else {
                return false
            }
            return true
        }
        markFeedback("正在准备书签行操作。")
        let task = Task {
            [weak self] in
            guard let self else {
                return false
            }
            defer {
                if self.bookmarkActions.generation == generation {
                    self.bookmarkActions.task = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try BookmarkPlan.prepare(
                        action: action,
                        snapshot: snapshot,
                        bookmarks: bookmarks,
                        generation: bookmarkGeneration,
                        replacement: replacement,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                }
                let plan = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 先复验全部来源，再执行任何剪贴板或正文副作用，不能发布过期计划的半份结果。
                guard current(), let source = authority.document else {
                    if !self.closing, self.bookmarkActions.generation == generation {
                        self.markFeedback("正文、书签、输入或光标已改变，旧书签行计划已停止。")
                    }
                    return false
                }
                if action.changesClipboard || action == .replace {
                    guard NSPasteboard.general.changeCount == clipboard else {
                        self.markFeedback("剪贴板已改变，旧书签行计划已停止。")
                        return false
                    }
                }
                if let text = plan.copiedText {
                    let item = NSPasteboardItem()
                    guard item.setString(text, forType: .string) else {
                        throw NateError.message("无法准备书签行剪贴板内容，正文保留。")
                    }
                    // 剪切的正文删除依赖完整复制成功，系统拒绝剪贴板写入时不得继续删除。
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects([item]) else {
                        throw NateError.message("系统未接受书签行复制，正文保留。")
                    }
                }
                var edited = false
                if let transaction = plan.transaction {
                    edited = try source.buffer.commit(transaction)
                }
                if let updated = plan.bookmarks {
                    source.buffer.bookmarks = updated
                }
                // 本任务已完成发布，后续正文通知只取消其它旧任务，不能把成功动作误报为取消。
                self.bookmarkActions.task = nil
                self.recordBookmarkAction(action, generation: recording)
                if edited {
                    self.didEdit()
                }
                else {
                    window.refreshEditors()
                    self.refreshUI()
                }
                self.markFeedback("书签行操作完成 · \(plan.affectedLines) 行。")
                return true
            }
            catch {
                if !self.closing, self.bookmarkActions.generation == generation {
                    self.markFeedback(error is CancellationError ? "书签行操作已取消。" : error.localizedDescription)
                }
                return false
            }
        }
        bookmarkActions.task = task
        return task
    }

    /// 业务作用：菜单只依据当前权限与集合规模判断行操作能力，不展开源正文或读取剪贴板。
    /// 参数说明:
    /// - id: 需要验证的稳定书签动作。
    /// 返回：书签菜单给出实际可用性，其他菜单返回空继续原验证流程。
    func validateBookmarkMenu(_ id: String) -> Bool? {
        if id == "cancelBookmarkAction" {
            return bookmarkActions.task != nil
        }
        guard let action = BookmarkAction(rawValue: id) else {
            return nil
        }
        guard
            let context = currentMarkEditor(
                modifying: action != .copy && action != .next && action != .previous
            ),
            !action.changesText || !context.document.buffer.isReadOnly
        else {
            return false
        }
        switch action {
        case .toggle, .invert, .deleteOthers: return true
        default: return !context.document.buffer.bookmarks.isEmpty
        }
    }
}
