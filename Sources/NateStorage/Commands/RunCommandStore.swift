import Darwin
import Foundation
import NateCore

public struct RunCommandLibraryRead: Sendable {
    public let library: RunCommandLibrary?
    public let baseline: DiskBaseline?
}

public struct RunCommandStore: Sendable {
    private let storage: RecoveryStore
    private let requestedDirectory: URL
    public var directory: URL {
        requestedDirectory
    }

    /// 业务作用：命名运行配置拥有独立固定目录，导入内容和配置名称都不能改变存储位置。
    /// 参数说明:
    /// - directory: 应用明确提供的专属目录，父目录须已建立。
    /// 返回：保留原末级身份、逐次拒绝目录改向的存储实例。
    public init(directory: URL) {
        let fixed: URL
        do {
            try FileStorage.validateFileURL(directory)
            // 专属末级必须保持原入口，初始化时的链接同样不能取得其它目录的覆盖权。
            fixed = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        }
        catch {
            fixed = directory
        }
        requestedDirectory = fixed
        storage = RecoveryStore(directory: fixed)
    }

    /// 业务作用：完整可解释归档才能安装为当前命令库，缺失与损坏不能混为同一空配置。
    /// 参数说明:
    /// - permit: 本轮有界读取仍有效的资格。
    /// 返回：完整命令库与原基线，真正缺失为空；超量、链接、未知或损坏明确失败。
    public func load(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> RunCommandLibraryRead {
        guard let current = try read(permit: permit) else {
            return RunCommandLibraryRead(library: nil, baseline: nil)
        }
        return RunCommandLibraryRead(
            library: try RunCommandArchive.decode(current.data, permit: permit),
            baseline: current.baseline
        )
    }

    /// 业务作用：完整配置编码先于目录副作用，原基线与格式通过后才发布全部定义。
    /// 参数说明:
    /// - library: 用户明确保留的完整配置列表。
    /// - expected: 最后读取的原文件证据，空值要求入口真正缺失。
    /// - rebuilding: 用户是否明确确认替换不可读原配置。
    /// - permit: 本轮发布仍有效的资格。
    /// 返回：实际同步后的新基线；冲突拒绝覆盖，发布后同步失败不报告成功。
    public func publish(
        _ library: RunCommandLibrary,
        expected: DiskBaseline?,
        rebuilding: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && ContinuousClock.now < deadline
        }
        let data = try RunCommandArchive.encode(library, permit: allowed)
        let target = directory.appendingPathComponent("commands.dat")
        _ = try storage.recoveryParent(target)
        let current = try read(permit: allowed)
        // 明确重建仍只拥有确认时的原文件，不能覆盖后来出现的新配置。
        guard current?.baseline == expected else {
            throw NateError.message("磁盘运行配置已经改变，原文件未覆盖。")
        }
        if !rebuilding, let current {
            _ = try RunCommandArchive.decode(current.data, permit: allowed)
        }
        if let current, current.data == data {
            return current.baseline
        }
        try createDirectory(permit: allowed)
        return try FileStorage.save(
            data,
            to: target,
            expected: expected,
            resolvingDirectoryLinks: false,
            permit: allowed
        )
    }

    /// 业务作用：重建确认固定原字节证据，不因格式无法解释就授予任意覆盖资格。
    /// 参数说明:
    /// - permit: 当前完整读取仍有效的资格。
    /// 返回：普通文件原基线或真正缺失，不解析命令也不改写内容。
    public func baseline(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline? {
        try read(permit: permit)?.baseline
    }

    /// 业务作用：创建专属目录只沿已经验证的父描述符，不在最后时刻重新跟随可变路径链接。
    /// 参数说明:
    /// - permit: 目录建立仍有效的资格。
    /// 返回：末级是无链接的实际目录时继续，取消或改向明确失败。
    private func createDirectory(permit: @Sendable () -> Bool) throws {
        let parent = try DirectoryContents.openDirectory(
            root: URL(fileURLWithPath: "/", isDirectory: true),
            directory: directory.deletingLastPathComponent(),
            permit: permit
        )
        defer {
            Darwin.close(parent)
        }
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        // 父目录权威已固定，mkdirat 不会把新目录建立到后来改向的入口。
        if Darwin.mkdirat(parent, directory.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = Darwin.openat(
            parent,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw NateError.message("运行配置目录不是无链接的实际目录，原路径保留。")
        }
        Darwin.close(descriptor)
    }

    /// 业务作用：固定配置只通过无链接普通文件通道读取，字段和名称永远不成为读取路径。
    /// 参数说明:
    /// - permit: 本次原字节读取资格。
    /// 返回：最多 8 MiB 的完整原字节与基线，缺失为空，其它失败拒绝。
    private func read(permit: @escaping @Sendable () -> Bool) throws -> FileReadEvidence? {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        let target = directory.appendingPathComponent("commands.dat")
        guard try storage.recoveryFileExists(target) else {
            return nil
        }
        return try storage.readRecoveryFile(
            target,
            maximumBytes: RunCommandArchive.maximumBytes,
            permit: permit
        )
    }
}
