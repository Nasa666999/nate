import Foundation
import NateStorage
import os

enum FileOperationResult: Sendable {
    case running
    case succeeded
    case cancelled
    case failed(String)
}

struct FileOperationSnapshot: Sendable {
    let id: UUID
    let title: String
    let target: URL
    let documentID: UUID?
    let revision: UInt64?
    let targetGeneration: UInt64?
    let stage: FileSaveStage
    let started: ContinuousClock.Instant
    let stageStarted: ContinuousClock.Instant
    let finished: ContinuousClock.Instant?
    let result: FileOperationResult
    let permissionRevoked: Bool
    let publication: PublicationStatus
    let hasActivePublication: Bool
    var canCancel: Bool {
        finished == nil && !permissionRevoked && publication == .unused
    }
    var requiresReconciliation: Bool {
        guard case .failed = result else {
            return false
        }
        switch stage {
        case .publishing, .published, .synchronizingDirectory, .confirmingSavedFile: return true
        default: return false
        }
    }
}

private struct FileOperationState {
    var stage = FileSaveStage.queued
    var stageStarted = ContinuousClock.now
    var finished: ContinuousClock.Instant?
    var result = FileOperationResult.running
}

final class FileOperationRequest: Sendable {
    let id = UUID()
    let title: String
    let target: URL
    let documentID: UUID?
    let revision: UInt64?
    let targetGeneration: UInt64?
    let permission: CancellationToken
    let started = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: FileOperationState())
    var snapshot: FileOperationSnapshot {
        state.withLock {
            value in
            FileOperationSnapshot(
                id: id,
                title: title,
                target: target,
                documentID: documentID,
                revision: revision,
                targetGeneration: targetGeneration,
                stage: value.stage,
                started: started,
                stageStarted: value.stageStarted,
                finished: value.finished,
                result: value.result,
                permissionRevoked: permission.isCancelled,
                publication: permission.publicationStatus,
                hasActivePublication: permission.hasActivePublication
            )
        }
    }

    /// 业务作用：固定文件任务身份与发布权限，记录中不保留正文或编码后的完整数据。
    /// 参数说明:
    /// - title: 用户可识别的动作。
    /// - target: 原目标路径。
    /// - documentID: 可选文档生命周期。
    /// - revision: 可选固定正文修订。
    /// - targetGeneration: 可选目标绑定代次。
    /// - permission: 本次动作的单次发布权限。
    /// 返回：可跨 I/O 线程观察的独立请求。
    init(
        title: String,
        target: URL,
        documentID: UUID?,
        revision: UInt64?,
        targetGeneration: UInt64?,
        permission: CancellationToken
    ) {
        self.title = title
        self.target = target
        self.documentID = documentID
        self.revision = revision
        self.targetGeneration = targetGeneration
        self.permission = permission
    }

    /// 业务作用：只发布实际执行到的保存阶段，已经完成的请求不接受迟到进度。
    /// 参数说明:
    /// - stage: 文件动作当前执行阶段。
    /// 返回：阶段开始时刻随实际变化更新。
    func observe(_ stage: FileSaveStage) {
        state.withLock {
            value in
            guard value.finished == nil else {
                return
            }
            if value.stage != stage {
                value.stage = stage
                value.stageStarted = .now
            }
        }
    }

    /// 业务作用：仅在同步系统动作真正返回后记录完成，停止等待本身不能冒充底层结束。
    /// 参数说明:
    /// - error: 实际系统或操作失败；为空表示成功。
    /// 返回：首次完成生效，重复回传不改变原结论。
    func finish(error: (any Error)?) -> Bool {
        state.withLock {
            value in
            guard value.finished == nil else {
                return false
            }
            value.finished = .now
            if error is CancellationError {
                value.result = .cancelled
            }
            else if let error {
                value.result = .failed(error.localizedDescription)
            }
            else {
                value.result = .succeeded
            }
            return true
        }
    }
}

private struct FileLedgerState {
    var requests: [UUID: FileOperationRequest] = [:]
    var completed: [UUID] = []
    var acceptingPublications = true
}

final class FileOperationLedger: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: FileLedgerState())
    var snapshots: [FileOperationSnapshot] {
        let requests = state.withLock {
            Array($0.requests.values)
        }
        return requests.map(\.snapshot).sorted {
            if ($0.finished == nil) != ($1.finished == nil) {
                return $0.finished == nil
            }
            return $0.started > $1.started
        }
    }

    /// 业务作用：在排队或编码前登记完整请求，使长期未进入文件系统的任务也可观察和取消。
    /// 参数说明:
    /// - title: 实际动作名称。
    /// - target: 目标路径。
    /// - documentID: 文档生命周期。
    /// - revision: 固定正文修订。
    /// - targetGeneration: 原目标绑定代次。
    /// - permission: 已有动作令牌；为空时建立独立令牌。
    /// 返回：已登记请求，只保留最近 100 个真正完成的记录。
    func begin(
        title: String,
        target: URL,
        documentID: UUID? = nil,
        revision: UInt64? = nil,
        targetGeneration: UInt64? = nil,
        permission: CancellationToken? = nil
    ) -> FileOperationRequest {
        let request = FileOperationRequest(
            title: title,
            target: target,
            documentID: documentID,
            revision: revision,
            targetGeneration: targetGeneration,
            permission: permission ?? CancellationToken()
        )
        state.withLock {
            // 退出封闭入口后，新到请求仍可记录，但不能再取得磁盘发布权限。
            if !$0.acceptingPublications {
                request.permission.cancel()
            }
            $0.requests[request.id] = request
        }
        return request
    }

    /// 业务作用：同步操作的真实返回负责结束任务，不因 UI 的取消请求直接删除在途记录。
    /// 参数说明:
    /// - request: 原登记请求。
    /// - operation: 包含编码和文件访问的完整同步动作。
    /// 返回：实际值或实际错误，同时可靠记录完成状态。
    func perform<Value>(_ request: FileOperationRequest, operation: () throws -> Value) throws -> Value {
        do {
            try request.permission.check()
            request.observe(.preparingBytes)
            let result = try operation()
            complete(request, error: nil)
            return result
        }
        catch {
            complete(request, error: error)
            throw error
        }
    }

    /// 业务作用：任务真正结束后保留有限执行证据，清理不触碰仍可能产生副作用的任务。
    /// 参数说明:
    /// - request: 已结束的请求。
    /// - error: 实际结果中的失败原因。
    /// 返回：首次结论进入完成历史，旧记录按数量上限移除。
    func complete(_ request: FileOperationRequest, error: (any Error)?) {
        guard request.finish(error: error) else {
            return
        }
        // 动作已经返回时，未使用的权限也应撤销，完成历史不能成为新的发布入口。
        if request.permission.publicationStatus == .unused {
            request.permission.cancel()
        }
        state.withLock {
            value in
            value.completed.append(request.id)
            while value.completed.count > 100 {
                value.requests.removeValue(forKey: value.completed.removeFirst())
            }
        }
    }

    /// 业务作用：通用文件与配置写入取得独立请求身份和单次发布权。
    /// 参数说明:
    /// - access: 已装配的平台协调入口。
    /// - data: 已编码的固定字节。
    /// - url: 用户确认的目标。
    /// - expected: 必须匹配的磁盘基线。
    /// - replacing: 是否为另存替换。
    /// - permit: 外层动作仍有效的权限。
    /// - authority: 外层已派生的单次发布令牌。
    /// 返回：确认过的真实保存点，同时保留实际任务状态。
    func save(
        using access: CoordinatedFileAccess,
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        replacing: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        authority: CancellationToken? = nil
    ) throws -> DiskBaseline {
        let request = begin(title: "文件写入", target: url, permission: authority)
        return try perform(request) {
            try write(
                using: access,
                request: request,
                data,
                to: url,
                expected: expected,
                replacing: replacing,
                permit: permit
            )
        }
    }

    /// 业务作用：已登记的文档请求沿用同一令牌，把阶段与原子发布结果关联到固定修订。
    /// 参数说明:
    /// - access: 平台协调文件入口。
    /// - request: 包含编码阶段的已有请求。
    /// - data: 固定字节。
    /// - url: 原目标。
    /// - expected: 磁盘基线。
    /// - replacing: 是否为另存替换。
    /// - permit: 外层仍有效的动作权限。
    /// 返回：完整保存点，结束登记由包含整个同步动作的 perform 负责。
    func write(
        using access: CoordinatedFileAccess,
        request: FileOperationRequest,
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        replacing: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        try access.save(
            data,
            to: url,
            expected: expected,
            replacing: replacing,
            permit: {
                !request.permission.isCancelled && permit()
            },
            authority: request.permission,
            observe: {
                request.observe($0)
            }
        )
    }

    /// 业务作用：任务取消只撤销尚未使用的发布权，未返回的系统动作仍保留在登记中。
    /// 参数说明:
    /// - id: 用户选中的任务身份。
    /// 返回：找到在途任务时发出取消；不删除任务或声称系统已经停止。
    func cancel(_ id: UUID) {
        let request = state.withLock {
            $0.requests[id]
        }
        guard let request, request.snapshot.finished == nil else {
            return
        }
        request.permission.cancel()
    }

    /// 业务作用：退出收束时先封闭新发布入口，再撤销所有未使用权限，避免检查之后又新增写入者。
    /// 参数说明: 无。
    /// 返回：旧请求均已观察取消，新请求只能登记为无发布权任务；已进入系统发布的请求仍可见。
    func suspendPublications() {
        let requests = state.withLock {
            $0.acceptingPublications = false
            return Array($0.requests.values)
        }
        for request in requests where request.snapshot.finished == nil {
            request.permission.cancel()
        }
    }

    /// 业务作用：取消退出后允许用户发起新的明确动作，不恢复任何旧请求已经失去的权限。
    /// 参数说明: 无。
    /// 返回：仅后续新建请求可取得独立权限。
    func resumePublications() {
        state.withLock {
            $0.acceptingPublications = true
        }
    }

    /// 业务作用：用户清理展示历史时只移除真正结束的任务，保留未决系统副作用。
    /// 参数说明: 无。
    /// 返回：已完成展示记录清空，在途请求继续可观察。
    func clearCompleted() {
        state.withLock {
            value in
            for id in value.completed {
                value.requests.removeValue(forKey: id)
            }
            value.completed.removeAll()
        }
    }
}
