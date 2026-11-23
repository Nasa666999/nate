import Darwin
import Foundation

private struct DocumentModificationComputationBudget: Sendable {
    let thread: UInt32
    let started: UInt64

    /// 业务作用：同步分类按当前线程的实际计算时间计费，系统调度等待不消费编辑计算预算。
    /// 参数说明: 无。
    /// 返回：当前线程及可靠 CPU 起点；系统无法提供计算时钟时拒绝分类，不影响已确认正文。
    init() throws {
        guard let started = Self.currentCPUTime() else {
            throw NateError.message("无法读取修改历史计算时钟，正文与撤销保持。")
        }
        thread = pthread_mach_thread_np(pthread_self())
        self.started = started
    }

    /// 业务作用：整个同步候选共用八毫秒实际计算预算，执行线程改变不能取得另一线程的时间额度。
    /// 参数说明: 无。
    /// 返回：仍在同一线程、时钟单调且实际计算未超量时允许继续。
    func allows() -> Bool {
        guard pthread_mach_thread_np(pthread_self()) == thread,
            let current = Self.currentCPUTime(), current >= started
        else {
            return false
        }
        return current - started < 8_000_000
    }

    /// 业务作用：将系统线程 CPU 时钟转换为可检查的纳秒，失败或不可表示时不猜测零耗时。
    /// 参数说明: 无。
    /// 返回：有效线程纳秒；系统调用失败、非法字段或换算超量时为空。
    private static func currentCPUTime() -> UInt64? {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0,
            time.tv_sec >= 0, time.tv_nsec >= 0, time.tv_nsec < 1_000_000_000,
            UInt64(time.tv_sec) <= (UInt64.max - 999_999_999) / 1_000_000_000
        else {
            return nil
        }
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}

extension DocumentBuffer {
    /// 业务作用：呈现和导航只能使用当前正文对应的完整修改分类，等待保存点核对时不冒用旧类别。
    /// 参数说明: 无。
    /// 返回：分类可用时的固定快照；证据不足或计算暂停时为空，正文保持可编辑。
    public var modificationSnapshot: DocumentModificationSnapshot? {
        guard changeClassificationAvailable, let timeline = changeTimeline,
            timeline.ledger.state.length == text.byteCount
        else {
            return nil
        }
        return DocumentModificationSnapshot(
            documentID: id,
            revision: revision,
            generation: timeline.generation,
            state: timeline.ledger.state
        )
    }

    /// 业务作用：正文和唯一撤销历史已经确认后，修改呈现沿同一历史身份推进，不能反向拒绝已确认正文。
    /// 参数说明:
    /// - entry: 当前正文事务对应的唯一撤销项。
    /// - backwards: 为空表示新事务，否则明确表示撤销或重做。
    /// - undoCount: 正文内核仍保留的可撤销数量。
    /// 返回：完整历史在共同八毫秒线程计算及 250 毫秒经过时间内发布；失败只暂停分类并保留正文、保存和撤销。
    func recordDocumentModification(entry: HistoryEntry, backwards: Bool?, undoCount: Int) {
        guard var timeline = changeTimeline else {
            return
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            let budget = try DocumentModificationComputationBudget()
            let event: ChangeHistoryEvent
            if let backwards {
                event = backwards ? .undo(entry.id) : .redo(entry.id)
            }
            else {
                event = .edit(
                    try ChangeHistoryLedger.group(
                        id: entry.id,
                        changes: entry.forwardChanges,
                        deadline: deadline,
                        permit: {
                            budget.allows()
                        }
                    )
                )
            }
            try timeline.record(
                event,
                undoCount: undoCount,
                deadline: deadline,
                permit: {
                    budget.allows()
                }
            )
            guard budget.allows(), ContinuousClock.now < deadline else {
                throw NateError.message("修改历史分类超过八毫秒线程计算或 250 毫秒经过时间，未发布候选。")
            }
            guard timeline.ledger.state.length == text.byteCount else {
                throw NateError.message("修改历史与当前正文长度不一致。")
            }
            changeTimeline = timeline
        }
        catch {
            // 正文事务已经完整确认，显示元数据的失败没有撤回用户输入或消费另一套历史的权限。
            changeTimeline = nil
            changeClassificationAvailable = false
            modificationStatus = "修改历史分类已暂停，正文与撤销保持：" + error.localizedDescription
        }
    }
}
