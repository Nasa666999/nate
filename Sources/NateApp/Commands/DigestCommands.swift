import AppKit
import NateCore
import NateStorage
import os

private final class DigestProgress: Sendable {
    private let next = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    /// 业务作用：大文件进度只按有界频率交付界面，不让每个读取块堆积主线程回调。
    /// 参数说明: 无。
    /// 返回：创建只保留下一次交付时刻的进度门禁。
    init() {}

    /// 业务作用：同批文件共用进度频率，快速小文件也不会产生无限界面队列。
    /// 参数说明: 无。
    /// 返回：距上次交付至少一百毫秒时为真。
    func permit() -> Bool {
        next.withLock {
            next in
            let now = ContinuousClock.now
            guard now >= next else {
                return false
            }
            next = now.advanced(by: .milliseconds(100))
            return true
        }
    }
}

@MainActor
final class DigestRuntime {
    let io = IOExecutor(
        name: "nate.digests",
        concurrency: 1,
        maximumStalled: 0
    )
    var panel: DigestPanel?
    var task: Task<Void, Never>?

    /// 业务作用：摘要独立限制磁盘读取与文本计算，不占用正文写入或恢复通道。
    /// 参数说明: 无。
    /// 返回：尚未持有输入窗口或在途任务的运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：摘要取消保留真实后台任务至返回，不允许取消后立即堆积新的读取线程。
    /// 参数说明: 无。
    /// 返回：旧请求失去发布资格，底层在下一个取消边界退出。
    func cancelDigest() {
        digests.task?.cancel()
        if digests.task != nil {
            digests.panel?.status.stringValue = "已请求取消，等待本次实际读取返回。"
        }
    }

    /// 业务作用：四类算法各自提供直接文本、逐行、多文件与实际选区复制入口。
    /// 参数说明:
    /// - id: digest、算法和来源组成的稳定命令标识。
    /// 返回：合法命令打开独立窗口或请求真实正文选区摘要，不改写正文。
    func routeDigest(_ id: String) {
        let parts = id.split(separator: ":")
        // 未确认候选仍属于原编辑器，摘要入口不能通过打开窗口改变其输入生命周期。
        guard parts.count == 3, let algorithm = DigestAlgorithm(rawValue: String(parts[1])),
            !closing, mainWindow?.hasMarkedEditorInput != true
        else {
            return
        }
        if parts[2] == "selection" {
            guard let (_, _, editor) = quickFindContext(), let state = editor.viewSelectionState,
                state.entries.count == 1, case .stream = state.shape,
                let entry = state.entries.first, !entry.selection.range.isEmpty,
                entry.selection.virtualColumn == 0
            else {
                mainWindow?.status.stringValue = "选区摘要需要正文中的一个非空连续选区。"
                return
            }
            runTextTool(algorithm.rawValue)
            return
        }
        guard ["text", "lines", "files"].contains(String(parts[2])), digests.task == nil else {
            digests.panel?.showWindow(nil)
            return
        }
        digests.panel?.close()
        let panel = DigestPanel(
            algorithm: algorithm,
            lines: parts[2] == "lines"
        )
        panel.onText = {
            [weak self, weak panel] text, lines in
            guard let self, let panel else {
                return
            }
            self.computeDigestText(text, lines: lines, panel: panel)
        }
        panel.onFiles = {
            [weak self, weak panel] in
            guard let self, let panel else {
                return
            }
            self.chooseDigestFiles(panel: panel)
        }
        panel.onCancel = {
            [weak self] in
            self?.cancelDigest()
        }
        panel.onClose = {
            [weak self, weak panel] in
            if self?.digests.panel === panel {
                self?.digests.panel = nil
            }
        }
        digests.panel = panel
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        if parts[2] == "files" {
            chooseDigestFiles(panel: panel)
        }
    }

    /// 业务作用：固定输入文本在有界后台完整计算，输入往返改变也不能接收原结果。
    /// 参数说明:
    /// - text: 点击计算时固定的原输入。
    /// - lines: 是否排除每行实际行尾后独立摘要。
    /// - panel: 本次明确输入所在窗口。
    /// 返回：完整结果只交付原请求，不触碰系统剪贴板或正文。
    func computeDigestText(_ text: String, lines: Bool, panel: DigestPanel) {
        guard !closing, digests.panel === panel, digests.task == nil else {
            return
        }
        guard text.utf8.count <= 64 * 1024 * 1024 else {
            panel.status.stringValue = "文本摘要输入超过 64 MiB，未计算。"
            return
        }
        beginDigest(panel: panel) {
            token,
            _ in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let tree = PieceTree(text)
            if lines {
                return .lines(
                    try TextDigests.lines(
                        text: tree,
                        deadline: deadline,
                        permit: {
                            !token.isCancelled
                        }
                    )
                )
            }
            return .text(
                try TextDigests.values(
                    text: tree,
                    deadline: deadline,
                    permit: {
                        !token.isCancelled
                    }
                ),
                tree.byteCount
            )
        }
    }

    /// 业务作用：多文件摘要只读取用户本次明确选择的磁盘文件，不猜测正文或工作区路径。
    /// 参数说明:
    /// - panel: 发起文件选择的当前窗口。
    /// 返回：取消选择保持原结果，超过一千文件明确拒绝。
    func chooseDigestFiles(panel: DigestPanel) {
        guard !closing, digests.panel === panel, digests.task == nil else {
            return
        }
        let chooser = NSOpenPanel()
        chooser.title = "选择要计算原字节摘要的文件"
        chooser.canChooseDirectories = false
        chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = true
        guard chooser.runModal() == .OK, !closing, digests.panel === panel else {
            return
        }
        computeDigestFiles(chooser.urls, panel: panel)
    }

    /// 业务作用：每个文件协调读取并复验同一完整原字节证据，单项失败保留明确路径和原因。
    /// 参数说明:
    /// - urls: 用户明确选择的文件序列。
    /// - panel: 原结果接收窗口。
    /// 返回：整批完成后交付全部成功及失败项；取消不交付部分批次。
    func computeDigestFiles(_ urls: [URL], panel: DigestPanel) {
        guard !closing, digests.panel === panel, digests.task == nil else {
            return
        }
        guard !urls.isEmpty, urls.count <= 1000 else {
            panel.status.stringValue = "每次请选择 1 至 1000 个文件。"
            return
        }
        let access = fileAccess
        beginDigest(panel: panel) {
            token,
            progress in
            var results: [FileDigestOutcome] = []
            for (index, url) in urls.enumerated() {
                try token.check()
                progress("文件 \(index + 1) / \(urls.count) · \(String(reflecting: url.path)) · 已读取 0 字节")
                do {
                    let snapshot = try access.withRead(
                        at: url,
                        permit: {
                            !token.isCancelled
                        }
                    ) {
                        coordinated in
                        try FileStorage.digests(
                            coordinated,
                            progress: {
                                bytes in
                                progress(
                                    "文件 \(index + 1) / \(urls.count) · \(String(reflecting: url.path)) · 已读取 \(bytes) 字节"
                                )
                            },
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                    results.append(.success(url.path, snapshot))
                }
                catch is CancellationError {
                    throw CancellationError()
                }
                catch {
                    try token.check()
                    results.append(.failure(url.path, error.localizedDescription))
                }
            }
            try token.check()
            return .files(results)
        }
    }

    /// 业务作用：摘要计算只拥有原窗口请求的结果发布权，实际占用直到同步读取返回才解除。
    /// 参数说明:
    /// - panel: 当前输入与结果窗口。
    /// - operation: 固定来源的完整后台计算。
    /// 返回：有效完整结果可复制，关闭、输入改变或取消均不发布迟到结果。
    private func beginDigest(
        panel: DigestPanel,
        operation:
            @escaping @Sendable (CancellationToken, @Sendable (String) -> Void) throws -> DigestPanelResult
    ) {
        let runtime = digests, request = panel.begin(), token = CancellationToken()
        let frequency = DigestProgress()
        let progress: @Sendable (String) -> Void = {
            [weak panel] message in
            guard !token.isCancelled, frequency.permit() else {
                return
            }
            Task {
                @MainActor in
                guard let panel, !token.isCancelled, runtime.panel === panel, panel.request == request,
                    runtime.task != nil, panel.result == nil
                else {
                    return
                }
                panel.status.stringValue = message
            }
        }
        panel.status.stringValue = "正在完整计算，可取消；文件按磁盘原字节读取…"
        runtime.task = Task {
            [weak self, weak panel] in
            defer {
                runtime.task = nil
                panel?.setBusy(false)
                if Task.isCancelled, runtime.panel === panel, panel?.result == nil {
                    panel?.status.stringValue = "计算已取消，未发布部分结果。"
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await runtime.io.run {
                        try token.check()
                        return try operation(token, progress)
                    }
                } onCancel: {
                    token.cancel()
                }
                // 计算完成不授予已关闭窗口或新输入的发布权，取消后的完整结果同样丢弃。
                guard let self, let panel, !Task.isCancelled, !self.closing,
                    runtime.panel === panel, panel.request == request
                else {
                    return
                }
                panel.publish(result, request: request)
            }
            catch {
                guard let panel, !Task.isCancelled, runtime.panel === panel, panel.request == request else {
                    return
                }
                panel.status.stringValue = "未取得完整摘要：" + error.localizedDescription
            }
        }
    }
}
