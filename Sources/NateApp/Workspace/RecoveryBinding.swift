import Foundation
import NateCore
import NateStorage

extension ApplicationController {
    /// 业务作用：恢复正文立即可用，原路径仅在身份与字节证据一致后重新获得写入资格。
    /// 参数说明:
    /// - document: 带有未核验原路径的恢复文档。
    /// 返回：一致时关联原文件；缺失、冲突或等待超时保留独立正文与原始恢复证据。
    func verifyRecoveryBinding(_ document: WorkspaceDocument) {
        guard let path = document.pendingOriginalPath, document.url == nil else {
            return
        }
        document.originalBindingTask?.cancel()
        let request = UUID()
        document.originalBindingRequest = request
        let expected = document.pendingOriginalBaseline
        let encoding = document.encoding
        let catalog = codecs
        let executor = readIO
        document.originalBindingTask = Task {
            [weak self, weak document] in
            guard let self, let document else {
                return
            }
            defer {
                if document.originalBindingRequest == request {
                    document.originalBindingTask = nil
                }
            }
            do {
                let loaded = try await executor.read {
                    try FileStorage.load(URL(fileURLWithPath: path), encoding: encoding, catalog: catalog)
                }
                // 用户另存为、关闭或新一轮核验后，旧路径证据不得重新接管保存目标。
                guard !self.closing, !document.closing, document.url == nil,
                    document.originalBindingRequest == request, document.pendingOriginalPath == path,
                    self.documents.contains(where: {
                        $0 === document
                    })
                else {
                    return
                }
                guard loaded.baseline == expected else {
                    throw NateError.message("原文件已经变化，恢复正文保持独立，需比较或另存为。")
                }
                // 恢复核验可能晚于用户主动打开；原文件只能有一个可写缓冲区。
                guard self.targetReservations[loaded.baseline.resolvedPath] == nil,
                    !self.documents.contains(where: {
                        $0 !== document && $0.baseline?.resolvedPath == loaded.baseline.resolvedPath
                    })
                else {
                    throw NateError.message("原文件已在另一标签或文件动作中使用，恢复正文保持独立。")
                }
                document.url = loaded.url
                document.baseline = loaded.baseline
                document.savedText = loaded.tree
                document.savedEncoding = loaded.encoding
                document.pendingOriginalPath = nil
                document.pendingOriginalBaseline = nil
                document.failure = nil
                document.state = "原路径已核验"
                document.evaluateDirty()
            }
            catch is CancellationError {
                return
            }
            catch {
                guard document.originalBindingRequest == request, document.url == nil else {
                    return
                }
                document.failure = "原路径尚未获写入权：" + error.localizedDescription
                document.state = "恢复副本 · 原文件未改动"
            }
            self.refreshUI()
        }
    }
}
