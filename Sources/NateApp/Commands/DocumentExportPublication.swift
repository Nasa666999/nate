import Foundation
import NateCore
import NateStorage

extension ApplicationController {
    /// 业务作用：独立导出先复验目标及工作区占用，再取得单次磁盘发布权限，不冒用原文档的保存点。
    /// 参数说明:
    /// - prepared: 保存面板打开前已完整编码的固定作业。
    /// - url: 用户明确确认的独立导出目标。
    /// 返回：完整原子替换及磁盘确认成功后结束；取消、基线变化或占用冲突保留原目标。
    func publishDocumentExport(_ prepared: PreparedDocumentExport, to url: URL) async throws {
        try Task.checkCancellation()
        guard !closing else {
            throw CancellationError()
        }
        try FileStorage.validateFileURL(url)
        let operations = fileOperations, access = fileAccess
        let token = CancellationToken()
        let request = operations.begin(
            title: "富文本导出",
            target: url,
            documentID: prepared.documentID,
            revision: prepared.revision,
            permission: token
        )
        do {
            try await withTaskCancellationHandler {
                let target = try await fileIO.run {
                    try token.check()
                    request.observe(.checkingBaseline)
                    let baseline =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try access.baseline(
                            url,
                            permit: {
                                !token.isCancelled
                            }
                        ) : nil
                    let path =
                        baseline?.resolvedPath ?? url.resolvingSymlinksInPath().standardizedFileURL.path
                    try token.check()
                    return (baseline, path)
                }
                try Task.checkCancellation()
                // 系统读取可能等待授权或磁盘，返回后必须重新确认退出保护与本次动作资格。
                guard !closing, !token.isCancelled else {
                    throw CancellationError()
                }
                // 导出格式不同于原文件；原路径、待连接目标及硬链接别名均不能成为第二个写入者。
                guard
                    !documents.contains(where: { document in
                        let paths = [document.url?.standardizedFileURL.path, document.pendingOriginalPath]
                            .compactMap { $0 }
                        return paths.contains(url.standardizedFileURL.path) || paths.contains(target.1)
                            || [document.baseline, document.pendingOriginalBaseline].compactMap { $0 }
                                .contains { baseline in
                                    baseline.resolvedPath == target.1
                                        || target.0.map {
                                            $0.device == baseline.device && $0.inode == baseline.inode
                                        } == true
                                }
                    })
                else {
                    throw NateError.message("导出目标由当前工作区文档持有，请选择独立文件。")
                }
                guard reserveTarget(target.1, owner: request.id) else {
                    throw NateError.message("导出目标仍有其它文件动作，请等待完成后重试。")
                }
                defer {
                    releaseTarget(target.1, owner: request.id)
                }
                _ = try await fileIO.run {
                    try operations.perform(request) {
                        try operations.write(
                            using: access,
                            request: request,
                            prepared.data,
                            to: url,
                            expected: target.0,
                            replacing: true
                        )
                    }
                }
            } onCancel: {
                token.cancel()
            }
        }
        catch {
            // 排队拒绝或目标检查失败尚未进入同步写入，也必须结束同一登记，不能留下虚假在途动作。
            operations.complete(request, error: error)
            throw error
        }
    }
}
