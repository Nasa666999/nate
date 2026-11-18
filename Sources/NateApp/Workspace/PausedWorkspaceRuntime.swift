import AppKit
import NateCore
import NateUI

@MainActor
final class PausedWorkspaceRuntime {
    let io = IOExecutor(name: "nate.paused.workspace.read", concurrency: 1, maximumStalled: 0)
    var generation = UUID()
    var task: Task<Void, Never>?
    var published = false
    var failure: String?

    /// 业务作用：保留工作区读取独立于当前恢复写入，慢归档不能占用正文保护通道。
    /// 参数说明: 无。
    /// 返回：尚未登记任何导入的独立运行状态。
    init() {}
}

@MainActor
final class PausedWorkspaceOrigin {
    private weak var window: EditorWindow?
    private weak var document: WorkspaceDocument?
    private weak var responder: NSResponder?
    private weak var keyWindow: NSWindow?
    let isEditorOrigin: Bool
    private let revision: UInt64?
    private let selection: UUID
    private let focus: UUID
    private let movement: UUID
    private let query: UUID
    private let input: SearchRequestInput

    /// 业务作用：导入等待只保留原导航资格，不把后台完成当成用户重新选择的焦点。
    /// 参数说明:
    /// - application: 发起导入的当前工作区控制器。
    /// - window: 发起导入的真实原生窗口。
    /// 返回：正文实例、修订、选区、焦点和查找输入的轻量证据。
    init(application: ApplicationController, window: EditorWindow) {
        self.window = window
        document = application.active
        responder = window.window?.firstResponder
        keyWindow = NSApp.keyWindow
        isEditorOrigin = NSApp.keyWindow === window.window && window.window?.firstResponder === window.editor
        revision = application.active?.buffer.revision
        selection = window.editor.selectionGeneration
        focus = window.editor.focusGeneration
        movement = application.searchNavigationGeneration
        query = application.queryGeneration
        input = SearchRequestInput(application.findWindow)
    }

    /// 业务作用：仅原导航意图仍存在时切换导入文档，候选输入和往返移动不会重新授予旧资格。
    /// 参数说明:
    /// - application: 发布时的当前工作区。
    /// 返回：窗口、正文、修订、选区、焦点与查找证据均未改变时为真。
    func matches(_ application: ApplicationController) -> Bool {
        guard let window, let document, !application.closing,
            application.mainWindow === window, application.active === document,
            window.editor.document === document.buffer,
            document.buffer.revision == revision,
            window.editor.selectionGeneration == selection,
            window.editor.focusGeneration == focus,
            application.searchNavigationGeneration == movement,
            application.queryGeneration == query,
            input.matches(application.findWindow),
            !window.hasMarkedEditorInput, !window.incrementalSearch.isEditingInput,
            application.findWindow?.isEditingInput != true,
            NSApp.keyWindow === keyWindow,
            window.window?.firstResponder === responder
        else {
            return false
        }
        return true
    }
}
