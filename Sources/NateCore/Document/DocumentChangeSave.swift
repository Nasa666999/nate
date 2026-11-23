import Foundation

public struct DocumentChangeSavePoint: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    let checkpoint: ChangeHistoryCheckpoint
}

public struct DocumentChangeSaveRequest: Sendable {
    let documentID: UUID
    let revision: UInt64
    let replay: ChangeHistoryReplayRequest
}

public struct PreparedDocumentChangeSave: Sendable {
    let request: DocumentChangeSaveRequest
    let ledger: ChangeHistoryLedger

    /// 业务作用：后台在实际写入快照上建立保存类别，再重放其后输入、撤销和分支，避免误标新正文。
    /// 参数说明:
    /// - request: 同一文档的固定保存点、当前发布身份及连续事件。
    /// - deadline: 完整保存重放的共同计算截止。
    /// - permit: 该写盘结果仍属于有效文档、目标与操作。
    /// 返回：可短时复验发布的完整分类；超量、取消或证据不足时不返回部分结果。
    public init(
        _ request: DocumentChangeSaveRequest,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        ledger = try ChangeHistoryTimeline.prepareSaved(request.replay, deadline: deadline, permit: permit)
        self.request = request
    }
}

extension DocumentBuffer {
    /// 业务作用：写盘开始前在主执行域与正文快照一并捕获修改历史位置。
    /// 参数说明: 无。
    /// 返回：当前完整历史存在时的固定保存点；分类计算已暂停时为空，不影响文件写入。
    public func changeHistorySavePoint() -> DocumentChangeSavePoint? {
        guard let timeline = changeTimeline, timeline.ledger.state.length == text.byteCount else {
            return nil
        }
        do {
            return DocumentChangeSavePoint(
                documentID: id,
                revision: revision,
                checkpoint: try timeline.checkpoint()
            )
        }
        catch {
            // 不能遗失已确认保存事实后继续声称颜色精确；正文和磁盘通道保持独立可用。
            changeTimeline = nil
            changeClassificationAvailable = false
            modificationStatus = "修改历史保存证据已暂停，可关闭重开文档重新建立：" + error.localizedDescription
            return nil
        }
    }

    /// 业务作用：原文件成功写入后暂停旧分类，固定当前后续事件供后台完整核对。
    /// 参数说明:
    /// - point: 实际成功写盘的固定正文在写入前捕获的保存点。
    /// 返回：同一生命周期且连续事件完整时建立请求；失败保留正文并停止显示无法证明的旧分类。
    public func changeHistorySaveRequest(for point: DocumentChangeSavePoint) throws
        -> DocumentChangeSaveRequest
    {
        guard point.documentID == id, point.revision <= revision, var timeline = changeTimeline,
            point.checkpoint.epoch == timeline.epoch
        else {
            throw NateError.message("修改历史保存点不属于当前可用正文。")
        }
        // 原文件基线已经推进，旧类别不再拥有当前保存事实的证明，等待期间不能继续显示猜测颜色。
        changeClassificationAvailable = false
        modificationStatus = "修改历史保存点正在核对"
        do {
            let replay = try timeline.replayRequest(from: point.checkpoint)
            changeTimeline = timeline
            return DocumentChangeSaveRequest(
                documentID: id,
                revision: revision,
                replay: replay
            )
        }
        catch {
            // 已确认写盘但失去完整事实链后不能从后来快照跳过旧保存点，重新打开才能建立可信起点。
            changeTimeline = nil
            modificationStatus = "修改历史保存证据已暂停，可关闭重开文档重新建立：" + error.localizedDescription
            throw error
        }
    }

    /// 业务作用：复验后台分类的正文修订与完整历史代次，迟到结果不能覆盖后来输入或撤销。
    /// 参数说明:
    /// - prepared: 已完成完整计算的保存分类。
    /// 返回：来源保持时一次发布并恢复分类显示；来源变化时不改动当前正文和历史。
    @discardableResult
    public func commitChangeHistorySave(_ prepared: PreparedDocumentChangeSave) -> Bool {
        guard prepared.request.documentID == id, prepared.request.revision == revision,
            changeTimeline?.publishSaved(prepared.ledger, for: prepared.request.replay) == true
        else {
            return false
        }
        changeClassificationAvailable = true
        modificationStatus = nil
        return true
    }

    /// 业务作用：保存事实已推进但分类尚无完整证据时停止颜色声明，后续成功保存仍可重新核对。
    /// 参数说明:
    /// - reason: 来源、预算或完整计算不足的用户可理解原因。
    /// 返回：正文和唯一历史保持，只暂停无法证明的修改分类并显示原因。
    public func pauseChangeHistoryClassification(reason: String) {
        changeClassificationAvailable = false
        modificationStatus = "修改历史保存分类暂不可用：" + reason
    }
}
