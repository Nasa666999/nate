import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class ClipboardHistoryRuntime {
    var enabled = false
    var ready = false
    var url: URL?
    var baseline: DiskBaseline?
    var failure: String?
    var task: Task<Void, Never>?
    var pending: [ClipboardHistoryRecord]?
    var clearGeneration = UUID()
    var panel: ClipboardHistoryPanel?
    let io = IOExecutor(name: "nate.clipboard.history", concurrency: 1, maximumStalled: 0)

    /// 业务作用：历史归档独立串行持有来源和保存基线，不占用原文件与恢复正文通道。
    /// 参数说明: 无。
    /// 返回：默认不持久化、不读取其它应用剪贴板的运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：只在取得应用数据目录后配置历史路径，默认关闭时不读取已有正文归档。
    /// 参数说明: 无。
    /// 返回：明确启用时启动受限恢复；缺少目录则保留本次内存历史。
    func configureClipboardHistory() {
        guard let applicationSupport else {
            return
        }
        historyPersistence.url = applicationSupport.appendingPathComponent("ClipboardHistory.dat")
        if historyPersistence.enabled {
            beginClipboardHistoryLoad(restoring: true)
        }
    }

    /// 业务作用：用户明确切换持久化，旧归档读取和正在发布的文件必须先完成，不能交叉更换保存基线。
    /// 参数说明:
    /// - enabled: 用户明确选择的新持久化偏好。
    /// 返回：空闲时生效并回显；关闭只停止后续保存，已有归档保留供明确清空。
    func setClipboardHistoryPersistence(_ enabled: Bool) {
        guard !closing, historyPersistence.task == nil else {
            refreshClipboardHistoryPanel()
            return
        }
        guard !enabled || historyPersistence.url != nil else {
            historyPersistence.failure = "应用数据目录不可用，历史仍仅保留在当前运行中。"
            refreshClipboardHistoryPanel()
            return
        }
        historyPersistence.enabled = enabled
        clipboardDefaults?.set(enabled, forKey: "persistClipboardHistory")
        historyPersistence.pending = nil
        if enabled {
            // 停用期间外部文件可能改变，重新启用不能沿旧基线直接覆盖。
            historyPersistence.ready = false
            beginClipboardHistoryLoad(restoring: true)
        }
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：历史完整恢复后才授予基线写入权，期间的新复制优先，明确清空不被迟到旧记录复活。
    /// 参数说明:
    /// - restoring: 为真时恢复旧记录，为假时只验证待清空归档的完整性。
    /// 返回：启动唯一读取任务；未知格式、容量或损坏保留原文件并停止自动覆盖。
    private func beginClipboardHistoryLoad(restoring: Bool) {
        let runtime = historyPersistence
        guard runtime.task == nil, let url = runtime.url else {
            return
        }
        let clear = runtime.clearGeneration
        runtime.task = Task {
            defer {
                finishClipboardHistoryTask()
            }
            do {
                let (loaded, baseline) = try await runtime.io.readCancellable {
                    token -> ([ClipboardHistoryRecord], DiskBaseline?) in
                    try token.check()
                    try FileStorage.validateFileURL(url)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return ([], nil)
                    }
                    let bytes = try self.fileAccess.readData(
                        url,
                        maximumBytes: ClipboardHistoryLimits.archiveBytes,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let records = try ClipboardHistoryArchive.decode(
                        bytes.data,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    try token.check()
                    return (records, bytes.baseline)
                }
                if restoring, runtime.clearGeneration == clear {
                    var merged = loaded
                    for record in clipboardHistory.reversed() {
                        merged = ClipboardHistoryLimits.inserting(record, into: merged)
                    }
                    clipboardHistory = merged
                    if merged != loaded {
                        runtime.pending = merged
                    }
                }
                else if restoring, runtime.enabled {
                    // 清空之后的新复制可以保存，清空之前的磁盘记录没有重新加入的资格。
                    runtime.pending = clipboardHistory
                }
                runtime.baseline = baseline
                runtime.ready = true
                runtime.failure = nil
            }
            catch {
                // 未完整识别的归档保持原样，普通复制和关闭面板都不能成为重建授权。
                runtime.ready = false
                runtime.failure = "历史归档未恢复，原文件保留。可明确选择“重新保存归档”：" + error.localizedDescription
            }
        }
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：主动动作只更新最新待保存完整历史，实际文件发布始终由唯一串行任务排空。
    /// 参数说明: 无。
    /// 返回：启用时排队最新历史；关闭时不保存新内容，未知归档不会被自动重建。
    func scheduleClipboardHistoryPersistence() {
        let runtime = historyPersistence
        guard runtime.enabled else {
            return
        }
        runtime.pending = clipboardHistory
        beginClipboardHistoryDrain()
    }

    /// 业务作用：清空立即撤销旧恢复记录的加入权，并顺序清空已保存历史，不读取系统剪贴板。
    /// 参数说明: 无。
    /// 返回：内存立即清空；合法已知归档写入空列表，未知归档保留并提示明确重建。
    func clearClipboardHistory() {
        let runtime = historyPersistence
        runtime.clearGeneration = UUID()
        clipboardHistory = []
        runtime.pending = []
        if runtime.ready {
            beginClipboardHistoryDrain()
        }
        else if runtime.task == nil {
            // 关闭持久化时也可能有既有归档，明确清空先验证该文件，不能把未知格式默默改为空默认值。
            beginClipboardHistoryLoad(restoring: false)
        }
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：只沿当前完整文件基线顺序发布历史，后来的清空和新记录不会被旧保存越过。
    /// 参数说明: 无。
    /// 返回：至多启动一个排空任务，失败停止后续覆盖并保留内存与磁盘现场。
    private func beginClipboardHistoryDrain() {
        let runtime = historyPersistence
        guard runtime.ready, runtime.task == nil, runtime.pending != nil, let url = runtime.url else {
            return
        }
        runtime.task = Task {
            defer {
                finishClipboardHistoryTask()
            }
            while let records = runtime.pending {
                runtime.pending = nil
                let expected = runtime.baseline
                do {
                    let baseline = try await runtime.io.runCancellable {
                        token in
                        let bytes = try ClipboardHistoryArchive.encode(
                            records,
                            permit: {
                                !token.isCancelled
                            }
                        )
                        // 编码和原基线均已完整取得，再授予这一次文件替换；下一状态须等待实际保存确认。
                        return try self.fileAccess.save(
                            bytes,
                            to: url,
                            expected: expected,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                    runtime.baseline = baseline
                    runtime.failure = nil
                }
                catch {
                    // 发布后确认失败也可能改变实际文件，旧基线不可用于无条件重试。
                    runtime.ready = false
                    runtime.failure = "历史归档尚未确认保存，原内容保留；可明确重新保存：" + error.localizedDescription
                    return
                }
            }
        }
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：唯一任务释放句柄后才启动后续最新状态，读写之间不并发发布同一归档。
    /// 参数说明: 无。
    /// 返回：更新实际忙碌状态并按当前已确认基线继续排空。
    private func finishClipboardHistoryTask() {
        historyPersistence.task = nil
        beginClipboardHistoryDrain()
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：用户明确确认后才覆盖未知或失去基线的归档，确认不替代实际完整文件证据。
    /// 参数说明: 无。
    /// 返回：重新取得完整受限文件基线后保存当前内存；取消、超量或读取失败保留原文件。
    func resetClipboardHistoryArchive() {
        let runtime = historyPersistence
        guard !closing, runtime.task == nil, let url = runtime.url else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "使用当前历史重新保存归档？"
        alert.informativeText = "将使用当前 \(clipboardHistory.count) 条完整记录覆盖：\n\(url.path)\n已有归档内容将被替换。"
        alert.addButton(withTitle: "重新保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, runtime.task == nil, !closing else {
            return
        }
        runtime.ready = false
        runtime.pending = clipboardHistory
        runtime.task = Task {
            defer {
                finishClipboardHistoryTask()
            }
            do {
                let baseline = try await runtime.io.readCancellable {
                    token -> DiskBaseline? in
                    try token.check()
                    try FileStorage.validateFileURL(url)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return nil
                    }
                    return try self.fileAccess.readData(
                        url,
                        maximumBytes: ClipboardHistoryLimits.archiveBytes,
                        permit: {
                            !token.isCancelled
                        }
                    ).baseline
                }
                // 确认只允许替换刚读到的那一份完整归档，读取期间变化仍由保存基线拒绝。
                runtime.baseline = baseline
                runtime.ready = true
                runtime.failure = nil
            }
            catch {
                runtime.failure = "历史归档未重新保存，原文件保留：" + error.localizedDescription
            }
        }
        refreshClipboardHistoryPanel()
    }

    /// 业务作用：面板只显示当前完整内存和真实文件状态，不因后台更新夺取编辑焦点。
    /// 参数说明: 无。
    /// 返回：当前列表、持久化选项、忙碌与失败一致回显。
    func refreshClipboardHistoryPanel() {
        let runtime = historyPersistence
        runtime.panel?.update(
            records: clipboardHistory,
            persisted: runtime.enabled,
            busy: runtime.task != nil,
            failure: runtime.failure
        )
    }
}
