import AppKit
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：恢复任务按已确认的入口与实际阶段显示，不把正文分块完成冒充整个工作区已保存。
    /// 参数说明: 无。
    /// 返回：不持有正文或发布权限的完整任务行，窗口刷新只读取轻量快照。
    func recoveryTaskPresentations() -> [FileTaskPresentation] {
        recoveryProgress.snapshots.map {
            record in
            let title: String
            switch record.kind {
            case .workspace: title = "工作区恢复保存"
            case .sidebar: title = "侧栏恢复保存"
            case .archive: title = "关闭内容保留"
            }
            let status: String
            let failed: Bool
            var detail = "任务：" + record.id.uuidString
            switch record.result {
            case .running:
                status = record.entryConfirmed ? "入口已确认 · 后续处理中" : "进行中 · 入口尚未确认"
                failed = false
            case .succeeded:
                status = record.entryConfirmed ? "本次快照已确认" : "已结束 · 未记录入口确认"
                failed = false
            case .failed(let reason):
                status = record.entryConfirmed ? "入口已确认 · 后续步骤未完成" : "未确认 · 当前内容保留"
                detail += "\n" + reason
                failed = true
            case .deferred(let reason):
                status = "本轮结束 · 等待重试"
                detail += "\n" + reason
                failed = false
            }
            if let id = record.currentDocument {
                detail += "\n文档：" + (record.names[id] ?? id.uuidString)
                if let revision = record.currentRevision {
                    detail += " · 本次正文修订 \(revision)"
                }
                if record.currentRevision != nil {
                    detail += " · 已确认 \(record.completedBytes)/\(record.documentBytes) 原字节"
                    detail += " · 分块 \(record.completedChunks)/\(record.documentChunks)"
                }
                else if record.kind == .archive {
                    detail += " · 复用已确认正文引用"
                }
            }
            if record.kind == .workspace {
                detail += "\n本轮清单 \(record.confirmedDocuments.count)/\(record.names.count)"
                detail += " · 工作区 \(record.totalDocuments) 文档 · 本轮正文 \(record.totalBytes) 原字节"
            }
            if let file = record.file {
                detail += "\n当前文件：" + file
            }
            let elapsed = record.started.duration(to: record.finished ?? .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return FileTaskPresentation(
                id: record.id,
                title: title,
                target: record.target,
                stage: recoveryTaskStage(record),
                status: status,
                elapsed: String(format: "%.1f 秒", seconds),
                detail: detail,
                cancellable: false,
                finished: record.finished != nil,
                failed: failed
            )
        }
    }

    /// 业务作用：存储事件映射为明确的恢复步骤，底层单文件同步与最终入口确认分别呈现。
    /// 参数说明:
    /// - record: 当前动作完整进度快照。
    /// 返回：当前真实阶段说明，分块计数只采用后台已确认的数量。
    private func recoveryTaskStage(_ record: RecoveryProgressRecord) -> String {
        switch record.event {
        case .waitingForStorage: return "等待后台或恢复目录"
        case .measuringStorage: return "核对恢复存储用量"
        case .preparingDocument: return "准备正文快照"
        case .verifyingChunk:
            return "核验分块 \(record.completedChunks + 1)/\(record.documentChunks)"
        case .chunkConfirmed:
            return "已确认分块 \(record.completedChunks)/\(record.documentChunks)"
        case .preparingManifest: return "准备恢复清单"
        case .verifyingManifest: return "核验已有恢复清单"
        case .writingManifest: return "写入恢复清单"
        case .manifestConfirmed: return "文档清单已确认"
        case .verifyingIndex(let documents): return "核验 \(documents) 文档入口"
        case .synchronizingDependencies: return "同步恢复依赖目录"
        case .retainingPreviousIndex: return "保护上一有效索引"
        case .publishingIndex: return "发布工作区入口"
        case .indexConfirmed: return "工作区入口已确认"
        case .verifyingSidebars: return "核验侧栏定义"
        case .sidebarsConfirmed: return "侧栏入口已确认"
        case .archivingDocument: return "保护关闭内容"
        case .archiveConfirmed: return "关闭保留入口已确认"
        case .collecting: return "核验依赖并回收无引用内容"
        case .fileStage(let target, let stage):
            let url = URL(fileURLWithPath: target)
            let role: String
            if url.pathExtension == "chunk" {
                role = "分块"
            }
            else if url.pathExtension == "snapshot" {
                role = "清单"
            }
            else if url.lastPathComponent.contains("previous") {
                role = "上一入口"
            }
            else {
                role = "恢复入口"
            }
            return role + " · " + fileTaskStage(stage)
        }
    }
}
