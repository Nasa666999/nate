import AppKit
import NateCore
import NateUI

@MainActor
final class MacroPlaybackRuntime {
    var generation = UUID()
    var taskID: UUID?
    var task: Task<Void, Never>?

    /// 业务作用：宏播放持有独立取消代次和实际任务，停止等待不冒充后台动作已经结束。
    /// 参数说明: 无。
    /// 返回：没有活动播放的初始状态。
    init() {}
}

@MainActor
struct MacroPlaybackProof {
    let document: WorkspaceDocument
    let window: EditorWindow
    let editor: EditorView
    let focus: UUID
    let editing: UUID
    let target: UInt64
    var revision: UInt64
    var documentSelection: UUID
    var viewSelection: UUID

    /// 业务作用：固定宏真实作用的文档实例、视图和控制代次，不能沿往返焦点或后来选择继续执行。
    /// 参数说明:
    /// - document: 原活动文档实例。
    /// - window: 原工作区窗口。
    /// - editor: 原实际正文焦点视图。
    /// 返回：输入法确认完成后的完整播放依据。
    init(document: WorkspaceDocument, window: EditorWindow, editor: EditorView) {
        self.document = document
        self.window = window
        self.editor = editor
        focus = editor.focusGeneration
        editing = document.buffer.editingAuthorityGeneration
        target = document.targetGeneration
        revision = document.buffer.revision
        documentSelection = document.buffer.selectionGeneration
        viewSelection = editor.selectionGeneration
    }

    /// 业务作用：宏自己的事务可以推进正文，但窗口、焦点和编辑权限必须一直属于原实例。
    /// 参数说明:
    /// - application: 当前工作区和真实焦点的唯一来源。
    /// 返回：全部控制证据未变化时为真，角色或焦点往返也失去资格。
    func matchesAuthority(_ application: ApplicationController) -> Bool {
        guard !Task.isCancelled, let (current, currentWindow, currentEditor) = application.quickFindContext()
        else {
            return false
        }
        return current === document && currentWindow === window && currentEditor === editor
            && editor.focusGeneration == focus && document.targetGeneration == target
            && document.buffer.editingAuthorityGeneration == editing && !document.buffer.isReadOnly
    }

    /// 业务作用：动作之间让出事件循环后复验上一项的真实结果，用户的新输入或选择不能成为旧宏的新起点。
    /// 参数说明:
    /// - application: 当前活动工作区。
    /// 返回：原控制证据及上一项发布的正文和选择均未变化时为真。
    func matches(_ application: ApplicationController) -> Bool {
        matchesAuthority(application) && document.buffer.revision == revision
            && document.buffer.selectionGeneration == documentSelection
            && editor.selectionGeneration == viewSelection
    }

    /// 业务作用：只在本项真实成功且控制证据仍有效后登记下一项来源，不接受让出事件循环期间的外来变更。
    /// 参数说明: 无。
    /// 返回：下一项使用刚完成动作的正文和完整选择代次。
    mutating func advance() {
        revision = document.buffer.revision
        documentSelection = document.buffer.selectionGeneration
        viewSelection = editor.selectionGeneration
    }
}

extension ApplicationController {
    /// 业务作用：菜单启动的宏保留实际任务，重复点击不会创建并发播放。
    /// 参数说明:
    /// - repetitions: 本次完整播放次数，必须为一至一万。
    /// 返回：合法且空闲时启动一项可取消播放；忙碌或范围无效时不替换现有任务。
    func startMacro(repetitions: Int) {
        guard (1...10_000).contains(repetitions), macroPlayback.task == nil, !macroPlaying,
            !macroRecording, !macroActions.isEmpty
        else {
            return
        }
        let runtime = macroPlayback
        let request = UUID()
        runtime.generation = request
        runtime.taskID = request
        runtime.task = Task {
            [weak self] in
            defer {
                if runtime.taskID == request {
                    runtime.task = nil
                    runtime.taskID = nil
                }
            }
            guard let self, runtime.generation == request else {
                return
            }
            await self.playMacro(repetitions: repetitions)
        }
    }

    /// 业务作用：明确停止先收回后续动作权限，再取消正在等待的计算，已提交步骤仍保留并可撤销。
    /// 参数说明: 无。
    /// 返回：旧播放不能取得下一项权限，实际任务返回前仍保持忙碌状态。
    func cancelMacro() {
        macroPlayback.generation = UUID()
        macroPlayback.task?.cancel()
    }

    /// 业务作用：宏菜单与实际录制、播放任务共用启用状态，不能在播放间隙替换动作列表。
    /// 参数说明:
    /// - item: 需要更新录制勾选状态的菜单项。
    /// - id: 统一命令标识。
    /// 返回：属于宏菜单时提供明确状态，其它命令为空。
    func validateMacroMenu(_ item: NSMenuItem, id: String) -> Bool? {
        let busy = macroPlaying || macroPlayback.task != nil
        switch id {
        case "recordMacro":
            item.state = macroRecording ? .on : .off
            return !closing && !busy && (macroRecording || quickFindContext() != nil)
        case "playMacro", "repeatMacro":
            return !closing && !busy && !macroRecording && !macroActions.isEmpty
                && quickFindContext() != nil && active?.buffer.isReadOnly == false
        case "cancelMacro":
            return busy
        case "saveMacro":
            return !closing && !busy && !macroRecording && !macroActions.isEmpty
        case "loadMacro":
            return !closing && !busy && !macroRecording
        default:
            return nil
        }
    }
}
