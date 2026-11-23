import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：真实原文件完成保存后核对固定保存点，连续输入时重新固定当前分类而不扩大旧写入范围。
    /// 参数说明:
    /// - point: 与实际写入正文一并捕获的原修改历史位置，分类已暂停时为空。
    /// - document: 已确认成功写入并发布原文件基线的文档。
    /// 返回：安排独立可取消的分类通道，不占用原文件保存任务；失败保留正文和真实保存事实。
    func scheduleSavedModifications(_ point: DocumentChangeSavePoint?, document: WorkspaceDocument) {
        document.modificationSaveTask?.cancel()
        document.modificationSaveGeneration = UUID()
        document.modificationSaveTask = nil
        guard let point else {
            return
        }
        let generation = document.modificationSaveGeneration
        let first: DocumentChangeSaveRequest
        do {
            // 写盘确认与旧颜色失效在同一主执行域片段发布，排队中的重绘不能继续采用旧保存事实。
            first = try document.buffer.changeHistorySaveRequest(for: point)
        }
        catch {
            document.buffer.pauseChangeHistoryClassification(reason: error.localizedDescription)
            mainWindow?.redrawModifications(documentID: document.buffer.id)
            return
        }
        document.modificationSaveTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if document.modificationSaveGeneration == generation {
                    document.modificationSaveTask = nil
                }
            }
            do {
                for attempt in 0..<4 {
                    // 写盘通道已经确认保存事实；只读派生分类绑定文档及最新票据，改名或取消关闭不抹去历史。
                    guard !Task.isCancelled,
                        document.modificationSaveGeneration == generation,
                        self.documents.contains(where: {
                            $0 === document
                        })
                    else {
                        return
                    }
                    let request =
                        try attempt == 0 ? first : document.buffer.changeHistorySaveRequest(for: point)
                    let worker = Task.detached(priority: .utility) {
                        try PreparedDocumentChangeSave(request)
                    }
                    let prepared = try await withTaskCancellationHandler(
                        operation: {
                            try await worker.value
                        },
                        onCancel: {
                            worker.cancel()
                        }
                    )
                    guard !Task.isCancelled,
                        document.modificationSaveGeneration == generation,
                        self.documents.contains(where: {
                            $0 === document
                        })
                    else {
                        return
                    }
                    if document.buffer.commitChangeHistorySave(prepared) {
                        self.mainWindow?.redrawModifications(documentID: document.buffer.id)
                        return
                    }
                }
                document.buffer.pauseChangeHistoryClassification(reason: "正文持续变化，等待下一次成功保存重新核对。")
            }
            catch {
                // 写盘结果已确认，分类失败不能把原文件成功说成失败，也不能清除后续需要保存的正文。
                guard document.modificationSaveGeneration == generation,
                    self.documents.contains(where: {
                        $0 === document
                    })
                else {
                    return
                }
                document.buffer.pauseChangeHistoryClassification(reason: error.localizedDescription)
            }
            self.mainWindow?.redrawModifications(documentID: document.buffer.id)
        }
    }
}
