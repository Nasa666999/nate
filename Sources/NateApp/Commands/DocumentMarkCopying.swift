import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：新的标记、清除、编辑或退出撤销旧标记文本复制，迟到输出不能覆盖系统剪贴板。
    /// 参数说明: 无。
    /// 返回：复制身份先失效，再取消后台任务并收回句柄。
    func cancelDocumentMarkCopy() {
        let pending = markCopyTask != nil
        markCopyGeneration = UUID()
        markCopyTask?.cancel()
        markCopyTask = nil
        if pending, !closing {
            markFeedback("标记文本复制已取消，剪贴板保留。")
        }
    }

    /// 业务作用：复制当前真实编辑视图所属文档的一个或多个颜色组，不改变查找输入、书签或正文。
    /// 参数说明:
    /// - styles: 用户明确选择复制的颜色组，重叠正文仅输出一次。
    /// 返回：原文档、标记身份与剪贴板仍有效时发布完整内容；失效、取消或超限保留剪贴板。
    func copyDocumentMarks(styles: [DocumentMarkStyle]) {
        cancelDocumentMarkCopy()
        guard let context = currentMarkEditor(modifying: false) else {
            return
        }
        let document = context.document
        let authority = SearchDocumentAuthority(document)
        let snapshot = document.buffer.markSnapshot
        let ranges = Set(styles).flatMap {
            snapshot.marks.ranges(for: $0)
        }
        let request = markCopyGeneration
        let clipboard = NSPasteboard.general.changeCount
        let current: @MainActor () -> Bool = {
            [weak self] in
            // 标记清除、正文修订与真实文档生命周期共同约束复制，稳定 UUID 不能复活旧正文。
            guard let self, !self.closing, !Task.isCancelled, self.markCopyGeneration == request,
                let document = authority.document,
                self.documents.contains(where: {
                    $0 === document
                }),
                authority.matches(document), document.buffer.markGeneration == snapshot.generation
            else {
                return false
            }
            return true
        }
        markFeedback("正在准备完整标记文本。")
        markCopyTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.markCopyGeneration == request {
                    self.markCopyTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try MarkedTextExport.prepare(
                        ranges,
                        tree: snapshot.document.text,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 全文成功且三类权限仍成立后才更新剪贴板，新复制内容属于更新的用户意图。
                guard current() else {
                    if !self.closing, self.markCopyGeneration == request {
                        self.markFeedback("正文或标记已改变，未复制旧标记文本；剪贴板保留。")
                    }
                    return
                }
                guard NSPasteboard.general.changeCount == clipboard else {
                    self.markFeedback("剪贴板已改变，未覆盖新内容；可重新复制标记文本。")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                self.markFeedback(
                    "已复制 \(result.fragments) 个标记片段。"
                        + (result.empty > 0 ? "\(result.empty) 个空匹配没有正文，未复制。" : "")
                )
            }
            catch {
                if current(), !(error is CancellationError) {
                    self.markFeedback(error.localizedDescription)
                }
                else if !self.closing, self.markCopyGeneration == request {
                    self.markFeedback("标记文本复制已停止，剪贴板保留。")
                }
            }
        }
    }
}
