import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

@MainActor
final class TextToolRuntime {
    let io = IOExecutor(
        name: "nate.text.tools",
        concurrency: 1,
        maximumStalled: 0
    )
    var generation = UUID()
    var task: Task<Void, Never>?
    var succeeded: UUID?
    var bytesPanel: ByteResultPanel?
    var exportTask: Task<Void, Never>?

    /// 业务作用：文本工具独立限制同步转换并保留实际占用，不与文件读写或进程执行相互阻塞。
    /// 参数说明: 无。
    /// 返回：初始没有待提交结果或字节窗口的运行状态。
    init() {}
}

private enum PreparedTextTool: Sendable {
    case text(PreparedTransaction)
    case bytes(Data)
    case digest(String)
}

extension ApplicationController {
    /// 业务作用：新的输入、选择或退出先撤销文本工具发布资格，真实工作句柄保留至计算退出。
    /// 参数说明: 无。
    /// 返回：取消不发布部分转换，不提前开放另一个计算通道。
    func cancelTextTool() {
        textTools.generation = UUID()
        textTools.task?.cancel()
        textTools.succeeded = nil
    }

    /// 业务作用：工具只接收一个真实连续选择，后台完成编解码与事务后再复验原控制权。
    /// 参数说明:
    /// - name: 菜单明确选择的稳定工具标识。
    /// 返回：合法输入进入有界独立通道；摘要、字节窗口和正文均只接受仍有效的完整结果。
    func runTextTool(_ name: String) {
        let digest = ["md5", "sha1", "sha256", "sha512"].contains(name)
        guard textTools.task == nil, let (document, window, editor) = quickFindContext(),
            digest || !document.buffer.isReadOnly,
            let state = editor.viewSelectionState, state.entries.count == 1,
            case .stream = state.shape, let entry = state.entries.first,
            entry.selection.virtualColumn == 0
        else {
            mainWindow?.status.stringValue = "文本工具需要正文中的一个连续选区或普通光标，且转换通道空闲。"
            return
        }
        cancelTextTool()
        let runtime = textTools, request = runtime.generation
        let snapshot = document.buffer.snapshot
        let range =
            entry.selection.range.isEmpty ? ByteRange(0, snapshot.text.byteCount) : entry.selection.range
        let proof = RunCommandSourceProof(
            document: document,
            window: window,
            editor: editor
        )
        let focus = editor.focusGeneration, board = NSPasteboard.general.changeCount
        let current: @MainActor () -> Bool = {
            [weak self] in
            guard let self, !Task.isCancelled, runtime.generation == request, proof.matches(self),
                let (_, actualWindow, actualEditor) = self.quickFindContext(), actualWindow === window,
                actualEditor === editor, editor.focusGeneration == focus,
                digest || !document.buffer.isReadOnly
            else {
                return false
            }
            return true
        }
        let token = CancellationToken()
        runtime.task = Task {
            defer {
                runtime.task = nil
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await runtime.io.run {
                        try token.check()
                        guard range.count <= MIMECodec.maximumBytes else {
                            throw NateError.message("工具完整输入超过 64 MiB，原内容保持不变。")
                        }
                        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                        if let algorithm = DigestAlgorithm(rawValue: name) {
                            let values = try TextDigests.values(
                                text: snapshot.text,
                                range: range,
                                deadline: deadline,
                                permit: {
                                    !token.isCancelled
                                }
                            )
                            return PreparedTextTool.digest(values.value(for: algorithm))
                        }
                        let source = snapshot.text.text(in: range)
                        let data: Data
                        if let operation = MIMEOperation(rawValue: name) {
                            data = try MIMECodec.transform(
                                operation,
                                data: Data(source.utf8),
                                deadline: deadline,
                                permit: {
                                    !token.isCancelled
                                }
                            )
                        }
                        else {
                            data = Data(try TextTools.transform(name, text: source).utf8)
                        }
                        try token.check()
                        guard data.count <= MIMECodec.maximumBytes, ContinuousClock.now < deadline else {
                            throw NateError.message("工具完整结果超过 64 MiB 或五秒预算，原内容保持不变。")
                        }
                        guard
                            let value = String(
                                data: data,
                                encoding: .utf8
                            )
                        else {
                            return PreparedTextTool.bytes(data)
                        }
                        let plan = try PreparedSelectionInsertion(
                            snapshot: snapshot,
                            targets: [
                                SelectionInsertionTarget(
                                    id: entry.id,
                                    range: range,
                                    text: value
                                )
                            ],
                            name: name,
                            permit: {
                                !token.isCancelled && ContinuousClock.now < deadline
                            }
                        )
                        return PreparedTextTool.text(plan.transaction)
                    }
                } onCancel: {
                    token.cancel()
                }
                // 完整结果不授予新焦点、候选或权限的写入权；往返到相同状态也必须重新请求。
                guard current() else {
                    return
                }
                switch result {
                case .text(let transaction):
                    let changed = try document.buffer.commit(transaction)
                    editor.refresh()
                    if changed {
                        self.didEdit()
                    }
                    window.status.stringValue = "文本转换已完整完成，可撤销。"
                case .bytes(let data):
                    self.showTextToolBytes(data, name: name)
                    window.status.stringValue = "解码得到非 UTF-8 字节，原文保持不变；完整结果已在独立窗口提供。"
                case .digest(let value):
                    // 等待时用户可能复制了新内容，摘要不能覆盖已经改变的剪贴板。
                    let copy = NSPasteboard.general.changeCount == board
                    if copy {
                        SystemIntegration.copy(value)
                    }
                    window.showResults(
                        "\(name.uppercased()) · UTF-8 原换行 · \(copy ? "已复制" : "剪贴板已改变，未覆盖")\n\(value)"
                    )
                }
                runtime.succeeded = request
            }
            catch {
                if current() {
                    window.status.stringValue = "转换未提交：" + error.localizedDescription
                }
            }
        }
        window.status.stringValue = "正在完整转换，可从工具菜单取消…"
    }
}
