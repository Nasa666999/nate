import Foundation
import NateStorage

extension ApplicationController {
    /// 业务作用：关闭保留使用同一实际存储入口，并为最后的归档索引写入提供独立可观察进度。
    /// 参数说明:
    /// - reference: 已确认正文及工作区保护的恢复引用。
    /// - store: 当前固定恢复存储与策略。
    /// 返回：实际归档完成后结束记录；失败保留原引用并向关闭流程传递，不提前移除文档。
    func archiveRecoveryReference(_ reference: RecoveryReference, using store: RecoveryStore) async throws {
        let ledger = recoveryProgress
        let progressID = ledger.begin(
            kind: .archive,
            target: store.directory.appendingPathComponent("closed-index.json"),
            names: [reference.id: reference.name ?? reference.id.uuidString],
            totalDocuments: 1,
            totalBytes: 0
        )
        let observed = store.observingProgress {
            ledger.observe($0, id: progressID)
        }
        do {
            try await recoveryIO.run {
                try observed.archive(reference)
            }
            ledger.finish(progressID)
        }
        catch {
            ledger.finish(
                progressID,
                failure: error.localizedDescription,
                retry: error is RecoveryStorageBusy
            )
            throw error
        }
    }
}
