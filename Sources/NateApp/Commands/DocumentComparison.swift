import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class DocumentComparisonRuntime {
    let io = IOExecutor(name: "io.github.nate.comparison", concurrency: 1, maximumStalled: 2)
    var task: Task<Void, Never>?
    var operation: UUID?
    var generation = UUID()
    var failure: String?

    /// 业务作用：比较计算拥有独立串行通道，取消后真实未返回的读取仍占用原动作身份。
    /// 参数说明: 无。
    /// 返回：没有任务或发布资格的独立比较状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：用户明确选择另一文件后才读取，比较不会确认候选、保存或替换工作区正文。
    /// 参数说明: 无。
    /// 返回：有效文件进入只读比较，取消选择不创建窗口或改变原文档。
    func compareDocuments() {
        guard !closing, documentComparison.task == nil, let active,
            mainWindow?.hasMarkedEditorInput == false
        else {
            return
        }
        guard active.buffer.text.byteCount <= TextComparison.maximumBytesPerSide else {
            mainWindow?.status.stringValue = "文档比较每侧最多 8 MiB，未截取部分正文。"
            return
        }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = fileDialogDirectory()
        chooser.message = "选择右侧文件；左侧使用当前文档的只读快照。"
        guard chooser.runModal() == .OK, let url = chooser.url else {
            return
        }
        beginDocumentComparison(with: url)
    }

    /// 业务作用：两份完整快照在后台求解后才发布窗口，正文或真实视图来源失效时拒绝迟到结果。
    /// 参数说明:
    /// - url: 用户明确选择的右侧文件。
    /// 返回：完整差异与颜色计划在独立只读窗口呈现；失败、取消或来源变化不修改任一文档。
    func beginDocumentComparison(with url: URL) {
        let runtime = documentComparison
        guard !closing, runtime.task == nil, let (document, window, editor) = quickFindContext(),
            !window.hasMarkedEditorInput
        else {
            return
        }
        let snapshot = document.buffer.snapshot
        guard snapshot.text.byteCount <= TextComparison.maximumBytesPerSide else {
            runtime.failure = "文档比较每侧最多 8 MiB，未截取部分正文。"
            refreshUI()
            return
        }
        let proof = RunCommandSourceProof(document: document, window: window, editor: editor)
        let originalTitle = document.url?.path ?? document.name
        let access = fileAccess, catalog = codecs
        let request = UUID(), generation = UUID()
        runtime.operation = request
        runtime.generation = generation
        runtime.failure = nil
        runtime.task = Task { [weak self] in
            defer {
                if runtime.operation == request {
                    runtime.task = nil
                    runtime.operation = nil
                }
                self?.refreshUI()
            }
            do {
                let incoming = try await runtime.io.readCancellable { token in
                    try access.load(
                        url,
                        catalog: catalog,
                        maximumBytes: TextComparison.maximumBytesPerSide + 4,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                // 读取只提供数据，原正文或交互身份已失效时不为旧快照建立后续计算和呈现资格。
                guard let self, !Task.isCancelled, !self.closing, runtime.generation == generation,
                    proof.matches(self)
                else {
                    throw CancellationError()
                }
                let original = DocumentBuffer(
                    text: snapshot.text,
                    format: snapshot.format
                )
                let revisedFormat = DocumentFormat(
                    codePage: incoming.encoding.codePage,
                    bom: incoming.encoding.bom,
                    lineEnding: incoming.lineEnding
                )
                let revised = DocumentBuffer(
                    text: incoming.tree,
                    format: revisedFormat
                )
                // 只有独立只读缓冲区进入比较呈现，颜色计划不持有工作区原文档的发布身份。
                original.isReadOnly = true
                revised.isReadOnly = true
                let left = original.markSnapshot, right = revised.markSnapshot
                window.status.stringValue = "正在计算完整文档差异，可在工具菜单取消。"
                let prepared = try await runtime.io.readCancellable { token in
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    let comparison = try TextComparison(
                        original: left.document.text,
                        revised: right.document.text,
                        deadline: deadline,
                        permit: {
                            !token.isCancelled && .now < deadline
                        }
                    )
                    let a = try PreparedDocumentMarks(
                        snapshot: left,
                        ranges: comparison.hunks.map(\.originalRange),
                        style: .style1,
                        append: false,
                        permit: {
                            !token.isCancelled && .now < deadline
                        }
                    )
                    let b = try PreparedDocumentMarks(
                        snapshot: right,
                        ranges: comparison.hunks.map(\.revisedRange),
                        style: .style2,
                        append: false,
                        permit: {
                            !token.isCancelled && .now < deadline
                        }
                    )
                    try token.check()
                    guard .now < deadline else {
                        throw NateError.message("文档差异与呈现准备超过五秒，未显示部分结果。")
                    }
                    return (comparison, a, b)
                }
                // 文件读取和计算都不授予覆盖权；发布前复验原正文、视图及全部交互控制身份。
                guard !Task.isCancelled, !self.closing, runtime.generation == generation, proof.matches(self)
                else {
                    throw CancellationError()
                }
                let controller = try TextComparisonWindow(
                    original: original,
                    revised: revised,
                    comparison: prepared.0,
                    originalMarks: prepared.1,
                    revisedMarks: prepared.2,
                    originalTitle: originalTitle,
                    revisedTitle: incoming.url.path,
                    formatDetail: "左：" + Self.comparisonFormat(snapshot.format) + "；右："
                        + Self.comparisonFormat(revisedFormat),
                    font: editor.font
                )
                controller.window?.appearance = window.window?.appearance
                controller.onClose = { [weak self, weak controller] in
                    self?.retainedWindows.removeAll {
                        $0 === controller
                    }
                }
                self.retainedWindows.append(controller)
                controller.showWindow(nil)
                controller.originalEditor.refresh()
                controller.revisedEditor.refresh()
                if !prepared.0.hunks.isEmpty {
                    controller.selectChange(0)
                }
                window.status.stringValue = "完整文档比较已打开，源文档保持原状。"
            }
            catch is CancellationError {
                if runtime.generation == generation {
                    runtime.failure = "比较已取消或来源改变，未发布旧结果。"
                }
            }
            catch {
                if !Task.isCancelled, runtime.generation == generation {
                    runtime.failure = "比较未完成：" + error.localizedDescription
                }
            }
        }
        mainWindow?.status.stringValue = "正在读取比较文件，可在工具菜单取消。"
    }

    /// 业务作用：取消撤销尚未发布的比较资格，真实读取返回前不启动第二个比较动作。
    /// 参数说明: 无。
    /// 返回：旧读取和计算不能创建窗口，现有只读比较窗口继续独立保留。
    func cancelDocumentComparison() {
        documentComparison.generation = UUID()
        documentComparison.task?.cancel()
        if documentComparison.task != nil {
            documentComparison.failure = "已请求取消文档比较。"
        }
    }

    /// 业务作用：文本差异与文件编码分别说明，正文相同不会掩盖 BOM 或默认换行规则差别。
    /// 参数说明:
    /// - format: 当前来源的完整文件格式。
    /// 返回：明确代码页、BOM 和插入换行的只读说明。
    private static func comparisonFormat(_ format: DocumentFormat) -> String {
        let name = format.codePage == 65001 ? "UTF-8" : "代码页 \(format.codePage)"
        return name + (format.bom ? "，有 BOM" : "，无 BOM") + "，插入换行 " + format.lineEnding.rawValue.uppercased()
    }
}
