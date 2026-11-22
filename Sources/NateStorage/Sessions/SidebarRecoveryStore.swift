import Foundation
import NateCore

public struct SidebarRecoveryRead: Sendable {
    public let state: SidebarRecoveryState?
    public let baseline: DiskBaseline?
    public let writable: Bool
    public let warning: String?

    /// 业务作用：将可用恢复值与自动覆盖资格分开，上一份可读快照不能替损坏的当前归档授予写入权。
    /// 参数说明:
    /// - state: 完整有效的当前或上一份侧栏状态，没有归档时为空。
    /// - baseline: 当前归档已取得的原字节证据。
    /// - writable: 两份现有归档均可识别且当前入口完整时为真。
    /// - warning: 使用回退或停止自动覆盖的具体原因。
    /// 返回：不含任何项目或目录访问权限的读取结果。
    init(state: SidebarRecoveryState?, baseline: DiskBaseline?, writable: Bool, warning: String?) {
        self.state = state
        self.baseline = baseline
        self.writable = writable
        self.warning = warning
    }
}

extension RecoveryStore {
    /// 业务作用：独立恢复项目与目录侧栏，两份归档均保留损坏证据，不因正文恢复失败而自动清空定义。
    /// 参数说明:
    /// - permit: 当前恢复读取仍有效的执行资格。
    /// 返回：当前有效归档优先，当前不可用时可读上一份但禁止自动覆盖；两份都不可读时失败，真正缺失返回空初始状态。
    public func restoreSidebars(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SidebarRecoveryRead {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && .now < deadline
        }
        var current: FileReadEvidence?
        var state: SidebarRecoveryState?
        var failure: String?
        var previous: SidebarRecoveryState?
        var previousFailure: String?
        do {
            current = try readSidebar(previous: false, permit: allowed)
            state = try current.map {
                try SidebarRecoveryArchive.decode($0.data)
            }
        }
        catch {
            failure = error.localizedDescription
        }
        do {
            previous = try readSidebar(previous: true, permit: allowed).map {
                try SidebarRecoveryArchive.decode($0.data)
            }
        }
        catch {
            previousFailure = error.localizedDescription
        }
        guard allowed() else {
            throw CancellationError()
        }
        if let state {
            return SidebarRecoveryRead(
                state: state,
                baseline: current?.baseline,
                writable: previousFailure == nil,
                warning: previousFailure.map {
                    "上一份侧栏归档不可用，停止自动覆盖：" + $0
                }
            )
        }
        if let previous {
            // 回退只恢复可读定义，不能沿另一份快照的有效性覆盖损坏或缺失的当前入口。
            return SidebarRecoveryRead(
                state: previous,
                baseline: current?.baseline,
                writable: false,
                warning: "已恢复上一份侧栏状态；当前归档缺失或不可用，停止自动覆盖。" + (failure ?? "")
            )
        }
        if failure != nil || previousFailure != nil {
            throw NateError.message(
                "侧栏归档未恢复，原数据保留："
                    + [failure, previousFailure].compactMap {
                        $0
                    }.joined(separator: "；")
            )
        }
        return SidebarRecoveryRead(state: nil, baseline: nil, writable: true, warning: nil)
    }

    /// 业务作用：先保留上一份有效侧栏，再按原基线发布完整当前状态，未保存定义不依附原文件写入。
    /// 参数说明:
    /// - state: 经过完整业务验证的候选侧栏状态。
    /// - expected: 调用方上一次确认的当前归档基线，空值要求当前入口不存在。
    /// - rebuilding: 用户是否明确要求用当前状态替换两份归档；普通周期不得开启。
    /// - permit: 本次发布仍有效的执行资格。
    /// 返回：实际当前归档已同步后的新基线；未知、损坏、冲突或失权失败，不把部分发布当成已保存。
    public func publishSidebars(
        _ state: SidebarRecoveryState,
        expected: DiskBaseline?,
        rebuilding: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        let deadline = min(
            .now.advanced(by: .seconds(5)),
            storageBudget?.deadline ?? .now.advanced(by: .seconds(5))
        )
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && .now < deadline
        }
        guard allowed() else {
            throw CancellationError()
        }
        if storageBudget == nil {
            return try withStorageWrite(deadline: deadline, permit: allowed) {
                store in
                try store.publishSidebars(state, expected: expected, rebuilding: rebuilding, permit: allowed)
            }
        }
        progress(.verifyingSidebars)
        let data = try SidebarRecoveryArchive.encode(state)
        // 创建目录也属于外部副作用，根或祖先已经改向时必须先拒绝，不能在新目标创建恢复材料。
        _ = try recoveryParent(directory.appendingPathComponent("sidebars.plist"))
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let current = try readSidebar(previous: false, permit: allowed)
        // 原基线失效必须先拒绝，不能为了轮换上一份记录而先覆盖另一份仍有价值的恢复状态。
        guard current?.baseline == expected else {
            throw NateError.message("侧栏恢复归档已改变，未覆盖任何恢复状态。")
        }
        let previous = try readSidebar(previous: true, permit: allowed)
        var retained: SidebarRecoveryState?
        if !rebuilding {
            retained = try current.map {
                try SidebarRecoveryArchive.decode($0.data)
            }
            _ = try previous.map {
                try SidebarRecoveryArchive.decode($0.data)
            }
            guard current != nil || previous == nil else {
                throw NateError.message("当前侧栏入口缺失，上一份保留；请明确重新保存侧栏恢复状态。")
            }
            if let current, current.data == data {
                // 先前目录同步可能尚未确认，相同正文只能省去替换，不能省去对持久化容器的确认。
                try synchronizeRecoveryDirectories(includingChunks: false, deadline: deadline)
                try storageBudget?.verifyContainers(store: self)
                progress(.sidebarsConfirmed)
                return current.baseline
            }
        }
        let previousData =
            try rebuilding
            ? data
            : retained.map {
                try SidebarRecoveryArchive.encode(sidebarFallback($0, preserving: state))
            }
        if let old = previousData {
            // 上一份先完整同步，当前入口随后发布，崩溃不会让两份都指向尚未完成的内容。
            _ = try saveRecoveryData(
                old,
                to: directory.appendingPathComponent("sidebars.previous.plist"),
                expected: previous?.baseline,
                permit: allowed
            )
        }
        // 文件发布仍复验相同原基线，轮换期间外部修改也不能取得覆盖许可。
        let saved = try saveRecoveryData(
            data,
            to: directory.appendingPathComponent("sidebars.plist"),
            expected: expected,
            permit: allowed
        )
        progress(.sidebarsConfirmed)
        return saved
    }

    /// 业务作用：显式重建前取得当前侧栏入口的原字节证据，仍拒绝链接、超限或目录改向。
    /// 参数说明:
    /// - permit: 本次确认读取仍有效的执行资格。
    /// 返回：当前普通归档的基线，真正缺失为空；本函数不解码或写入任何状态。
    public func sidebarBaseline(permit: @escaping @Sendable () -> Bool) throws -> DiskBaseline? {
        try readSidebar(previous: false, permit: permit)?.baseline
    }

    /// 业务作用：上一份可保留较早草稿，但不能重新恢复已卸载或明确放弃的项目，以及已关闭或换根的目录。
    /// 参数说明:
    /// - old: 当前入口仍有效的完整旧快照。
    /// - current: 本次即将发布的完整新快照。
    /// 返回：保留可回退编辑且遵守新关闭、保存点和面板显示意图的有效上一份状态。
    private func sidebarFallback(_ old: SidebarRecoveryState, preserving current: SidebarRecoveryState)
        -> SidebarRecoveryState
    {
        var fallback = old
        for index in current.projects.indices {
            let project = current.projects[index]
            if project.workspace == nil || project.workspace == project.saved {
                fallback.projects[index] = project
            }
        }
        if current.directory?.root.utf8.elementsEqual(old.directory?.root.utf8 ?? "".utf8) != true {
            fallback.directory = current.directory
        }
        fallback.projectsVisible = current.projectsVisible
        fallback.selectedProject = current.selectedProject
        return fallback
    }

    /// 业务作用：固定两份侧栏路径只通过恢复目录的无链接读取通道访问，不接受归档内路径作为存储位置。
    /// 参数说明:
    /// - previous: 是否读取上一份侧栏归档。
    /// - permit: 当前原字节读取资格。
    /// 返回：有界普通文件的全部证据，真正缺失为空，其它类型、超限或读取变化失败。
    private func readSidebar(previous: Bool, permit: @escaping @Sendable () -> Bool) throws
        -> FileReadEvidence?
    {
        let url = directory.appendingPathComponent(previous ? "sidebars.previous.plist" : "sidebars.plist")
        guard try recoveryFileExists(url) else {
            return nil
        }
        return try readRecoveryFile(url, maximumBytes: SidebarRecoveryArchive.maximumBytes, permit: permit)
    }
}
