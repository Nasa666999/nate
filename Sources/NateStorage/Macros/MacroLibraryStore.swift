import Foundation
import NateCore

public struct MacroLibraryRead: Sendable {
    public let snapshot: MacroLibrarySnapshot?
    public let baseline: DiskBaseline?
    public let writable: Bool
    public let warning: String?
}

public struct MacroLibraryStore: Sendable {
    private let storage: RecoveryStore
    public var directory: URL {
        storage.directory
    }

    /// 业务作用：命名宏使用独立固定目录，不与正文恢复索引或用户导出的宏文件共享覆盖权限。
    /// 参数说明:
    /// - directory: 本实例专属的应用数据目录。
    /// 返回：后续每次访问均复验父目录与普通文件的宏库存储。
    public init(directory: URL) {
        storage = RecoveryStore(directory: directory)
    }

    /// 业务作用：当前宏库损坏时可查看上一份，但缺失或未知入口不会沿回退结果取得自动覆盖权。
    /// 参数说明:
    /// - permit: 当前完整读取仍有效的执行资格。
    /// 返回：完整有效库、原入口基线与覆盖资格；两份都不可用时保留文件并失败。
    public func load(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> MacroLibraryRead {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && .now < deadline
        }
        var current: FileReadEvidence?
        var snapshot: MacroLibrarySnapshot?
        var currentFailure: String?
        var previous: MacroLibrarySnapshot?
        var previousFailure: String?
        do {
            current = try read(previous: false, permit: allowed)
            snapshot = try current.map {
                try MacroLibraryArchive.decode($0.data, permit: allowed)
            }
        }
        catch {
            currentFailure = error.localizedDescription
        }
        do {
            previous = try read(previous: true, permit: allowed).map {
                try MacroLibraryArchive.decode($0.data, permit: allowed)
            }
        }
        catch {
            previousFailure = error.localizedDescription
        }
        guard allowed() else {
            throw CancellationError()
        }
        if let snapshot {
            return MacroLibraryRead(
                snapshot: snapshot,
                baseline: current?.baseline,
                writable: previousFailure == nil,
                warning: previousFailure.map {
                    "上一份宏库不可读，停止自动覆盖：" + $0
                }
            )
        }
        if let previous {
            return MacroLibraryRead(
                snapshot: previous,
                baseline: current?.baseline,
                writable: false,
                warning: "正在查看上一份宏库；当前入口缺失或不可读，停止自动覆盖。" + (currentFailure ?? "")
            )
        }
        if currentFailure != nil || previousFailure != nil {
            throw NateError.message(
                "宏库未载入，原数据保留："
                    + [currentFailure, previousFailure].compactMap {
                        $0
                    }.joined(separator: "；")
            )
        }
        return MacroLibraryRead(snapshot: nil, baseline: nil, writable: true, warning: nil)
    }

    /// 业务作用：宏库先保留仍有效的上一份定义，再按同一原基线发布当前完整列表。
    /// 参数说明:
    /// - snapshot: 用户当前明确保留的全部定义。
    /// - expected: 最后确认的当前归档原字节证据，空值要求入口不存在。
    /// - rebuilding: 用户是否明确选择用当前列表重新建立两份归档，普通保存不得开启。
    /// - permit: 本次完整发布仍有效的资格。
    /// 返回：当前归档实际同步后的新基线；冲突、未知或未决写入不被当作成功。
    public func publish(
        _ snapshot: MacroLibrarySnapshot,
        expected: DiskBaseline?,
        rebuilding: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && .now < deadline
        }
        let data = try MacroLibraryArchive.encode(snapshot, permit: allowed)
        let target = directory.appendingPathComponent("library.dat")
        _ = try storage.recoveryParent(target)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let current = try read(previous: false, permit: allowed)
        // 原入口变化必须先拒绝，不能先轮换上一份记录而消耗另一份仍有价值的定义。
        guard current?.baseline == expected else {
            throw NateError.message("磁盘宏库已经改变，未覆盖任何归档。")
        }
        let previous = try read(previous: true, permit: allowed)
        var fallback: MacroLibrarySnapshot?
        if !rebuilding {
            let old = try current.map {
                try MacroLibraryArchive.decode($0.data, permit: allowed)
            }
            _ = try previous.map {
                try MacroLibraryArchive.decode($0.data, permit: allowed)
            }
            guard current != nil || previous == nil else {
                throw NateError.message("当前宏库入口缺失，上一份已保留，请明确选择重新保存当前列表。")
            }
            if let current, current.data == data {
                return current.baseline
            }
            if let old {
                let identities = Set(snapshot.definitions.map(\.id))
                // 已明确删除的宏不能在当前入口受损后从上一份列表重新出现。
                fallback = try MacroLibrarySnapshot(
                    old.definitions.filter {
                        identities.contains($0.id)
                    }
                )
            }
        }
        let retained =
            try rebuilding
            ? data
            : fallback.map {
                try MacroLibraryArchive.encode($0, permit: allowed)
            }
        if let retained {
            // 上一份完整同步后才发布当前入口，崩溃不会把两份都指向尚未完成的内容。
            _ = try FileStorage.save(
                retained,
                to: directory.appendingPathComponent("library.previous.dat"),
                expected: previous?.baseline,
                permit: allowed
            )
        }
        return try FileStorage.save(data, to: target, expected: expected, permit: allowed)
    }

    /// 业务作用：明确重建前固定当前原字节基线，确认对话框不会授予覆盖后来外部变化的资格。
    /// 参数说明:
    /// - permit: 当前有界读取资格。
    /// 返回：普通入口的原基线，真正缺失为空；不解码或修改内容。
    public func baseline(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline? {
        try read(previous: false, permit: permit)?.baseline
    }

    /// 业务作用：两份固定宏库只通过无链接有界通道读取，不把归档内名称解释为磁盘路径。
    /// 参数说明:
    /// - previous: 是否读取上一份完整定义。
    /// - permit: 当前原字节读取资格。
    /// 返回：普通文件的完整内容与基线，真正缺失为空；链接、改向或超量拒绝。
    private func read(previous: Bool, permit: @escaping @Sendable () -> Bool) throws -> FileReadEvidence? {
        let url = directory.appendingPathComponent(previous ? "library.previous.dat" : "library.dat")
        guard try storage.recoveryFileExists(url) else {
            return nil
        }
        return try storage.readRecoveryFile(
            url,
            maximumBytes: MacroLibraryArchive.maximumBytes,
            permit: permit
        )
    }
}
