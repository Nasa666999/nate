import AppKit
import NateCore

struct EditorTextLinkSource: Equatable {
    let document: ObjectIdentifier
    let documentID: UUID
    let revision: UInt64
    let root: UUID
    let settings: TextLinkSettings
}

struct EditorTextLinkHover {
    let link: DocumentTextLink
    let page: DocumentTextLinkPage
}

@MainActor
final class EditorTextLinkRuntime {
    var source: EditorTextLinkSource?
    var generation = UUID()
    var task: Task<Void, Never>?
    var taskID: UUID?
    var requested: Set<Int> = []
    var pages: [Int: DocumentTextLinkPage] = [:]
    var refused: [Int: String] = [:]
    var hovered: EditorTextLinkHover?
    var hoverWindowPoint: NSPoint?
    var tracking: NSTrackingArea?
    var status: String?

    /// 业务作用：每个正文视图独立持有链接页与悬停状态，克隆不共享鼠标位置或迟到任务。
    /// 参数说明: 无。
    /// 返回：尚未取得任何正文或点击来源的空运行状态。
    init() {}

    /// 业务作用：正文生命周期或配置改变时立即撤销旧分析和点击证据，不能因后来恢复相同值复活旧任务。
    /// 参数说明: 无。
    /// 返回：任务被取消，来源代次推进，页、失败记录及悬停目标全部清除；正文与选择保持。
    func reset() {
        task?.cancel()
        task = nil
        taskID = nil
        requested = []
        generation = UUID()
        source = nil
        pages = [:]
        refused = [:]
        hovered = nil
        hoverWindowPoint = nil
        status = nil
    }
}
