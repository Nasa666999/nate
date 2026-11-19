import AppKit
import NateCore
import NateUI

@MainActor
final class HistoryActionRuntime {
    var generation = UUID()
    var task: Task<Void, Never>?

    /// 业务作用：为尚未发布的历史准备保留独立身份，取消不消费文档历史。
    /// 参数说明: 无。
    /// 返回：没有活动历史动作的初始状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：新的正文意图或关闭收回历史准备的发布权，再停止后台计算。
    /// 参数说明: 无。
    /// 返回：当前正文和撤销、重做栈保持原状。
    func cancelHistoryAction() {
        historyAction.generation = UUID()
        historyAction.task?.cancel()
        historyAction.task = nil
    }

    /// 业务作用：后台完整准备当前颜色的撤销或重做，原焦点和所有控制证据仍成立时一次发布。
    /// 参数说明:
    /// - backwards: 为真撤销，为假重做。
    /// 返回：成功后刷新实际活动正文；等待期间改动、取消或超量均保留最新正文与历史。
    func performHistoryAction(backwards: Bool) {
        guard historyAction.task == nil,
            let (document, window, editor) = quickFindContext(allowingStaleRectangle: true),
            let source = document.buffer.historyRequest(backwards: backwards)
        else {
            return
        }
        cancelColumnInsertion()
        cancelLineSort()
        cancelMultipleSelection()
        cancelQuickFind()
        let runtime = historyAction
        let request = runtime.generation
        let selection = editor.selectionGeneration, focus = editor.focusGeneration
        let input = SearchRequestInput(findWindow)
        let movement = searchNavigationGeneration, query = queryGeneration
        let authority = SearchDocumentAuthority(document)
        let current: @MainActor () -> Bool = {
            [weak self, weak window, weak editor] in
            guard let self, let window, let editor, !Task.isCancelled,
                self.historyAction.generation == request,
                let (active, currentWindow, currentEditor) = self.quickFindContext(
                    allowingStaleRectangle: true
                ),
                active === document, currentWindow === window, currentEditor === editor,
                authority.matches(document), editor.selectionGeneration == selection,
                editor.focusGeneration == focus, self.searchNavigationGeneration == movement,
                self.queryGeneration == query, input.matches(self.findWindow)
            else {
                return false
            }
            return true
        }
        runtime.task = Task {
            defer {
                if runtime.generation == request {
                    runtime.task = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PreparedHistoryAction(source)
                }
                let action = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 焦点和导航属于用户最新意图，后台就绪不能让旧历史动作抢回已经离开的正文。
                guard current() else {
                    return
                }
                try document.buffer.commitHistory(action)
                editor.refresh(reveal: true)
                self.didEdit()
            }
            catch {
                if current() {
                    window.status.stringValue = "历史动作未执行，正文与历史保留：" + error.localizedDescription
                }
            }
        }
        window.status.stringValue = backwards ? "正在准备撤销，可从编辑菜单取消…" : "正在准备重做，可从编辑菜单取消…"
    }
}
