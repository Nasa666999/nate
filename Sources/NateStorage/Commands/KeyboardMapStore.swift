import Foundation
import NateCore
import Darwin

public struct KeyboardMapRead: Sendable {
    public let configuration: KeyboardMap?
    public let baseline: DiskBaseline?
}

public struct KeyboardMapStore: Sendable {
    private let storage: RecoveryStore
    private let requestedDirectory: URL
    public var directory: URL {
        requestedDirectory
    }

    /// 业务作用：快捷键设置独立于正文、宏库与用户导出文件，固定目录只保存本配置入口。
    /// 参数说明:
    /// - directory: 应用明确提供的设置专属目录，其父目录须预先建立。
    /// 返回：每次访问都复验父目录与普通文件身份的存储实例。
    public init(directory: URL) {
        let fixed: URL
        do {
            try FileStorage.validateFileURL(directory)
            // 专属目录的末级不能在初始化时沿链接改向；只固定原父目录，后续父目录门禁仍会核对完整路径。
            fixed = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        }
        catch {
            fixed = directory
        }
        requestedDirectory = fixed
        storage = RecoveryStore(directory: fixed)
    }

    /// 业务作用：只有完整受支持的归档才能成为当前用户覆盖，损坏或未知内容不能被当成空映射。
    /// 参数说明:
    /// - permit: 本轮完整读取仍有效的资格。
    /// 返回：有效配置与同一次读取的基线，真正缺失为空；超量、链接、损坏或取消明确失败。
    public func load(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> KeyboardMapRead {
        guard let current = try read(permit: permit) else {
            return KeyboardMapRead(configuration: nil, baseline: nil)
        }
        return KeyboardMapRead(
            configuration: try KeyboardMapArchive.decode(current.data, permit: permit),
            baseline: current.baseline
        )
    }

    /// 业务作用：完整编码先于目录或文件副作用，原基线与格式复验后才同步发布整份用户覆盖。
    /// 参数说明:
    /// - configuration: 用户当前明确保留的完整映射。
    /// - expected: 最后取得的原文件证据，空值要求入口真正不存在。
    /// - rebuilding: 用户是否明确选择替换不可读配置，普通管理不得开启。
    /// - permit: 当前发布仍有效的资格。
    /// 返回：实际保存后的基线；相同归档不重写，冲突或未知格式拒绝覆盖，发布后的同步失败不报告成功。
    public func publish(
        _ configuration: KeyboardMap,
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
        let data = try KeyboardMapArchive.encode(configuration, permit: allowed)
        let target = directory.appendingPathComponent("shortcuts.dat")
        _ = try storage.recoveryParent(target)
        let current = try read(permit: allowed)
        // 外部变化先于格式处理拒绝，明确重建同样不能覆盖确认之后新出现的内容。
        guard current?.baseline == expected else {
            throw NateError.message("磁盘快捷键设置已经改变，原文件未覆盖。")
        }
        if !rebuilding, let current {
            _ = try KeyboardMapArchive.decode(current.data, permit: allowed)
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

    /// 业务作用：明确重建前固定当前原字节证据，确认不能授予覆盖后来变化的资格。
    /// 参数说明:
    /// - permit: 当前有界读取资格。
    /// 返回：入口原基线，真正缺失为空；不解释或改写归档。
    public func baseline(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline? {
        try read(permit: permit)?.baseline
    }

    /// 业务作用：专属目录只能相对已验证的原父目录创建，路径切换不能把目录建立到其它位置。
    /// 参数说明:
    /// - permit: 创建末级目录时仍有效的发布资格。
    /// 返回：末级是无链接的真实目录时继续；父目录缺失、改向、取消或其它类型均失败。
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
        // 原父目录描述符已经固定，创建不会再次沿可变绝对路径解释链接。
        if Darwin.mkdirat(parent, directory.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let held = Darwin.openat(
            parent,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard held >= 0 else {
            throw NateError.message("快捷键设置目录不是无链接的普通目录，原路径保留。")
        }
        Darwin.close(held)
    }

    /// 业务作用：固定设置入口只通过无链接有界通道读取，归档中的命令身份永远不成为存储路径。
    /// 参数说明:
    /// - permit: 当前原字节读取资格。
    /// 返回：完整普通文件内容与证据，真正缺失为空；链接、改向或超过 1 MiB 拒绝。
    private func read(permit: @escaping @Sendable () -> Bool) throws -> FileReadEvidence? {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        let target = directory.appendingPathComponent("shortcuts.dat")
        guard try storage.recoveryFileExists(target) else {
            return nil
        }
        return try storage.readRecoveryFile(
            target,
            maximumBytes: KeyboardMapArchive.maximumBytes,
            permit: permit
        )
    }
}
