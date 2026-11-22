import Foundation
import NateStorage
import os

private struct RecoveryProgressState {
    var records: [UUID: RecoveryProgressRecord] = [:]
    var order: [UUID] = []
}

final class RecoveryProgressLedger: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: RecoveryProgressState())

    /// 业务作用：恢复动作只登记有界元数据，不保留正文树或文件发布权限，完成记录最多保留 64 项。
    /// 参数说明:
    /// - kind: 工作区、侧栏或关闭保留动作。
    /// - target: 当前固定恢复根目录。
    /// - names: 本轮实际更新的文档身份及名称。
    /// - totalDocuments: 本次索引包含的全部文档数量。
    /// - totalBytes: 本轮需要准备的正文原字节总量。
    /// 返回：独立进度身份，后续只接受该动作的实际阶段。
    func begin(
        kind: RecoveryProgressKind,
        target: URL,
        names: [UUID: String],
        totalDocuments: Int,
        totalBytes: Int
    ) -> UUID {
        let id = UUID()
        let bounded = Dictionary(
            uniqueKeysWithValues: names.prefix(1024).map {
                ($0.key, Self.displayName($0.value))
            }
        )
        state.withLock {
            current in
            current.records[id] = RecoveryProgressRecord(
                id: id,
                kind: kind,
                target: target.path,
                started: .now,
                names: bounded,
                totalDocuments: totalDocuments,
                totalBytes: totalBytes
            )
            current.order.append(id)
            Self.trim(&current)
        }
        return id
    }

    /// 业务作用：后台阶段仅更新自己的未完成记录，旧观察回调不能复活已清理记录或覆盖后继动作。
    /// 参数说明:
    /// - event: 存储层已经实际进入或确认的阶段。
    /// - id: 产生阶段的独立动作身份。
    /// 返回：轻量记录更新，正文和发布资格始终由原保存流程持有。
    func observe(_ event: RecoveryProgress, id: UUID) {
        state.withLock {
            current in
            guard var record = current.records[id], record.finished == nil else {
                return
            }
            record.event = event
            switch event {
            case .preparingDocument(let document, let revision, let bytes, let chunks):
                record.currentDocument = document
                record.currentRevision = revision
                record.documentBytes = bytes
                record.documentChunks = chunks
                record.completedBytes = 0
                record.completedChunks = 0
            case .verifyingChunk(let document, let bytes, let total, let chunks, let count),
                .chunkConfirmed(let document, let bytes, let total, let chunks, let count):
                record.currentDocument = document
                record.completedBytes = bytes
                record.documentBytes = total
                record.completedChunks = chunks
                record.documentChunks = count
            case .preparingManifest(let document, let revision),
                .verifyingManifest(let document, let revision), .writingManifest(let document, let revision):
                record.currentDocument = document
                record.currentRevision = revision
            case .manifestConfirmed(let document, let revision):
                record.currentDocument = document
                record.currentRevision = revision
                record.confirmedDocuments.insert(document)
            case .indexConfirmed, .sidebarsConfirmed:
                record.entryConfirmed = true
            case .archivingDocument(let document):
                record.currentDocument = document
            case .archiveConfirmed(let document):
                record.currentDocument = document
                record.confirmedDocuments.insert(document)
                record.entryConfirmed = true
            case .fileStage(let target, let stage):
                record.file = target
                record.fileStage = stage
            default: break
            }
            current.records[id] = record
        }
    }

    /// 业务作用：真实存储动作返回后才结束进度，索引已经确认而清理失败仍保留已保存证据。
    /// 参数说明:
    /// - id: 本次完成的稳定动作身份。
    /// - failure: 实际失败原因，为空表示全部步骤成功。
    /// - retry: 是否因临时占用结束并等待下一轮，而不是文件内容或配置异常。
    /// 返回：记录确认结束且不再接受迟到阶段，不把已发布入口说成尚未保存。
    func finish(_ id: UUID, failure: String? = nil, retry: Bool = false) {
        state.withLock {
            current in
            guard var record = current.records[id], record.finished == nil else {
                return
            }
            record.finished = .now
            if let failure {
                record.result = retry ? .deferred(failure) : .failed(failure)
            }
            else {
                record.result = .succeeded
            }
            current.records[id] = record
            Self.trim(&current)
        }
    }

    /// 业务作用：任务窗口只读取当前完整元数据快照，不跨锁访问正在更新的记录。
    /// 参数说明: 无。
    /// 返回：按建立顺序排列的全部在途及有限完成记录。
    var snapshots: [RecoveryProgressRecord] {
        state.withLock {
            current in
            current.order.compactMap {
                current.records[$0]
            }
        }
    }

    /// 业务作用：清除展示历史只移除已结束记录，不取消在途恢复或删除任何磁盘内容。
    /// 参数说明: 无。
    /// 返回：在途身份继续保留，迟到观察不能重建已移除的完成记录。
    func clearCompleted() {
        state.withLock {
            current in
            let removed = Set(
                current.order.filter {
                    current.records[$0]?.finished != nil
                }
            )
            for id in removed {
                current.records.removeValue(forKey: id)
            }
            current.order.removeAll {
                removed.contains($0)
            }
        }
    }

    /// 业务作用：完成历史按建立顺序有界保留，在途动作不因展示容量不足而消失。
    /// 参数说明:
    /// - current: 当前锁内的完整进度状态。
    /// 返回：最多保留 64 项完成记录，全部未结束记录保持可见。
    private static func trim(_ current: inout RecoveryProgressState) {
        let completed = current.order.filter {
            current.records[$0]?.finished != nil
        }
        let removed = Set(completed.prefix(max(0, completed.count - 64)))
        for id in removed {
            current.records.removeValue(forKey: id)
        }
        current.order.removeAll {
            removed.contains($0)
        }
    }

    /// 业务作用：展示名称只保留完整 UTF-8 前缀，超长标签不能让有限任务历史持有大量无关元数据。
    /// 参数说明:
    /// - name: 本轮固定的文档显示名称。
    /// 返回：最多 256 原字节的完整标量前缀与明确省略标记，不改变实际文档名称。
    private static func displayName(_ name: String) -> String {
        let prefix = Array(name.utf8.prefix(257))
        guard prefix.count > 256 else {
            return name
        }
        var bytes = Array(prefix.prefix(256))
        while String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self) + "…"
    }
}
