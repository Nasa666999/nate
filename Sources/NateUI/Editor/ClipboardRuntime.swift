import AppKit
import NateCore

@MainActor
final class ClipboardRuntime {
    static let type = NSPasteboard.PasteboardType("org.nate.clipboard")
    static let legacyType = NSPasteboard.PasteboardType("org.nate.text-fragments")
    var generation = UUID()
    var task: Task<Void, Never>?
    var workerCancel: (@Sendable () -> Void)?

    /// 业务作用：每个视图独立持有剪贴板准备权，焦点与选择变化不能借用其它视图动作。
    /// 参数说明: 无。
    /// 返回：尚无后台动作的运行状态。
    init() {}

    /// 业务作用：先撤销发布身份再取消计算，往返相同选择不能复活旧结果。
    /// 参数说明: 无。
    /// 返回：所有旧准备失去发布权，正文和剪贴板保持当前内容。
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        workerCancel?()
        workerCancel = nil
    }

    /// 业务作用：耗时编解码和正文构建离开主执行域，取消沿同一个动作传递到实际工作任务。
    /// 参数说明:
    /// - operation: 只捕获不可变可发送来源的完整准备过程。
    /// 返回：完整结果或失败，主执行域不等待同步文本计算。
    func prepare<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        workerCancel = {
            worker.cancel()
        }
        return try await withTaskCancellationHandler(
            operation: {
                try await worker.value
            },
            onCancel: {
                worker.cancel()
            }
        )
    }

    /// 业务作用：串行发布开始或动作结束只释放自己拥有的句柄，旧任务不能清除后续任务。
    /// 参数说明:
    /// - generation: 本轮开始时持有的发布身份。
    /// 返回：当前动作相同时释放句柄，否则保持新动作。
    func finish(_ generation: UUID) {
        if self.generation == generation {
            task = nil
            workerCancel = nil
        }
    }
}

@MainActor
struct ClipboardProof {
    let document: DocumentBuffer
    let snapshot: DocumentSnapshot
    let operation: UUID
    let selection: UUID
    let focus: UUID
    let editing: UUID
    let font: NSFont
    let wrapping: Bool
    let rtl: Bool
    let window: NSWindow
    let boardCount: Int?
    let modifying: Bool

    /// 业务作用：发布前完整复验原实例、选择、输入、视觉几何及剪贴板来源，ABA 往返仍拒绝。
    /// 参数说明:
    /// - editor: 原动作发起的实际原生视图。
    /// 返回：同一动作仍具有发布权时为真；不尝试把迟到结果重新绑定新来源。
    func matches(_ editor: EditorView) -> Bool {
        !Task.isCancelled && editor.clipboard.generation == operation
            && editor.document === document && document.revision == snapshot.revision
            && document.selectionGeneration == snapshot.selectionGeneration
            && editor.selectionGeneration == selection && editor.focusGeneration == focus
            && document.editingAuthorityGeneration == editing && editor.composition == nil
            && editor.viewSelectionState == snapshot.selectionState
            && editor.window === window && window.isKeyWindow && window.firstResponder === editor
            && editor.font == font && editor.wrapLines == wrapping && editor.rtl == rtl
            && (!modifying
                || !document.isReadOnly && !document.isEditingSuspended && document.revision < UInt64.max)
            && (boardCount.map {
                NSPasteboard.general.changeCount == $0
            } ?? true)
    }
}
