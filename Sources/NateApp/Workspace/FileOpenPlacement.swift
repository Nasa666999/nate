import NateCore
import NateUI

@MainActor
final class FileOpenPlacement {
    private(set) var window: EditorWindow?
    private(set) var needsWindow: Bool

    /// 业务作用：为一组打开请求固定原窗口和新建意图，后续路径共用同一已建立的窗口。
    /// 参数说明:
    /// - mode: Finder 或显式命令行的窗口策略。
    /// - origin: 请求开始时归属的编辑窗口。
    /// 返回：等待第一个有效目标、尚未创建额外窗口的请求状态。
    init(mode: FileOpenWindowMode, origin: EditorWindow?) {
        window = origin
        needsWindow = mode == .newWindow
    }

    /// 业务作用：首次成功打开的实际文件直接创建窗口，避免临时占位文档和重复可写缓冲区。
    /// 参数说明:
    /// - document: 已按磁盘身份统一的工作区文档。
    /// - application: 持有窗口和文档发布权的应用。
    /// 返回：已在相应窗口显示原缓冲区时为真；容量、关闭或候选门禁失败时保留原窗口。
    func present(_ document: WorkspaceDocument, using application: ApplicationController) -> Bool {
        if needsWindow {
            return prepareWindow(using: application, document: document) != nil
        }
        return application.activate(document.buffer.id, in: window)
    }

    /// 业务作用：目录、无文件命令或首个有效文件只建立同组所需的一扇窗口。
    /// 参数说明:
    /// - application: 持有窗口和文档发布权的应用。
    /// - document: 已验证的真实文件，打开目录或空窗口时留空。
    /// 返回：现有窗口或成功创建的新窗口；原窗口关闭或创建失败时为空。
    func prepareWindow(
        using application: ApplicationController,
        document: WorkspaceDocument? = nil
    ) -> EditorWindow? {
        // 异步调用前捕获的窗口必须仍登记，关闭原窗口后不能通过剩余路径产生新窗口。
        guard !application.closing, application.isWorkspaceWindowAvailable(window) else {
            return nil
        }
        if needsWindow {
            guard let created = application.openWorkspaceWindow(document: document) else {
                return nil
            }
            window = created
            needsWindow = false
        }
        return window
    }
}

extension ApplicationController {
    /// 业务作用：按系统事件逐组处理 Finder 路径，初始化前到达的事件也保留批次和顺序。
    /// 参数说明: 无。
    /// 返回：已有任务继续取出追加的请求；新任务完成组内全部路径后再取下一组。
    func startFinderOpenRequests() {
        guard initialized, !closing, finderOpenTask == nil, !pendingFinderURLs.isEmpty else {
            return
        }
        finderOpenTask = Task {
            defer {
                finderOpenTask = nil
            }
            while !closing, !Task.isCancelled, !pendingFinderURLs.isEmpty {
                let urls = pendingFinderURLs.removeFirst()
                let placement = FileOpenPlacement(
                    mode: currentFileOpeningSettings().finderWindowMode,
                    origin: mainWindow
                )
                for url in urls {
                    await openFile(url, placement: placement)
                }
            }
        }
    }
}
