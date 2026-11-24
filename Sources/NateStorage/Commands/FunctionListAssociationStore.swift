import Darwin
import Foundation
import NateCore

public struct FunctionListAssociationStore: Sendable {
    private static let maximumArchiveBytes = 18 * 1_048_576
    private static let useBundled = Data("NATE FUNCTION LIST ASSOCIATIONS USE BUNDLED\n".utf8)
    private let storage: RecoveryStore
    private let location: URL

    /// 业务作用：关联 XML 与全部规则原字节作为一个文件保存，应用启动时不会看到尚未发布的组合。
    /// 参数说明:
    /// - directory: 当前应用支持目录。
    /// 返回：独立于每语言规则的固定归档路径，支持目录的实际末级不可移向其它位置。
    public init(directory: URL) {
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        storage = RecoveryStore(directory: parent)
        location = parent.appendingPathComponent("function-list-associations.resource")
    }

    /// 业务作用：按同一磁盘读取获得完整原归档及其基线，真正缺失与明确恢复随包保持可区分。
    /// 参数说明:
    /// - permit: 本轮读取的有效资格。
    /// 返回：实际归档字节和基线；恢复随包时只有基线，未建立时为空。
    public func load(permit: @Sendable () -> Bool = { true }) throws -> (data: Data?, baseline: DiskBaseline)?
    {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard try storage.recoveryFileExists(location) else {
            return nil
        }
        let result = try storage.readRecoveryFile(
            location,
            maximumBytes: Self.maximumArchiveBytes,
            permit: permit
        )
        return (result.data == Self.useBundled ? nil : result.data, result.baseline)
    }

    /// 业务作用：经完整验证及确认的映射和依赖一次替换，防止比表单更新的磁盘内容被改写。
    /// 参数说明:
    /// - data: 已验证组合的原始归档；空值记录恢复随包的决定。
    /// - expected: 操作开始时取得的原磁盘基线。
    /// 返回：实际持久化的基线；有并行改写、超量或目录改向即拒绝。
    public func publish(_ data: Data?, expected: DiskBaseline?) throws -> DiskBaseline {
        if let data, data.isEmpty || data.count > Self.maximumArchiveBytes || data == Self.useBundled {
            throw NateError.message("函数列表关联归档超过容量或格式无效。")
        }
        let current = try load()
        // 重新读取用于发现冲突，旧表单不得从新的磁盘内容取得覆盖资格。
        guard current?.baseline == expected else {
            throw NateError.message("函数列表关联归档已改变，请重新载入。")
        }
        if let current, current.data == data {
            return current.baseline
        }
        return try FileStorage.save(
            data ?? Self.useBundled,
            to: location,
            expected: expected,
            resolvingDirectoryLinks: false
        )
    }

    /// 业务作用：只读取已选关联及同层依赖的原字节，文件名不能借符号链接或末级目录改向访问外部文件。
    /// 参数说明:
    /// - url: 已校验名称的关联文件或同目录规则路径。
    /// - directory: 本轮导入固定的实际目录路径。
    /// - stamp: 用户选择后固定的原目录身份和状态。
    /// - maximumBytes: 本文件的原字节预算。
    /// - collectBytes: 是否保留文件正文；只核对先前证据时按块计算摘要。
    /// - permit: 本轮导入的读取资格。
    /// 返回：普通文件的完整字节及同次证据；真正缺失为空，其余失败向上传递。
    public static func readImportXML(
        _ url: URL,
        in directory: URL,
        matching stamp: DirectoryStamp,
        maximumBytes: Int,
        collectBytes: Bool = true,
        permit: @Sendable () -> Bool
    ) throws -> FileByteSnapshot? {
        try FileStorage.validateFileURL(url)
        guard url.deletingLastPathComponent().standardizedFileURL.path.utf8.elementsEqual(directory.path.utf8)
        else {
            throw NateError.message("只能读取所选 overrideMap 同层的 XML。")
        }
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        let descriptor = try DirectoryContents.openDirectory(
            root: URL(fileURLWithPath: "/", isDirectory: true),
            directory: directory,
            permit: permit
        )
        defer {
            close(descriptor)
        }
        // 先核对已打开目录的身份，再以它为起点打开名称。检查路径字符串本身不能抵御读取中的目录替换。
        guard try DirectoryContents.stamp(descriptor) == stamp else {
            throw NateError.message("导入过程中函数列表目录已改变，请重新选择。")
        }
        var metadata = stat()
        guard fstatat(descriptor, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw NateError.message("所引用的函数列表规则不是普通文件。")
        }
        let result = try FileStorage.readEvidence(
            url,
            collectBytes: collectBytes,
            maximumBytes: maximumBytes,
            resolvingLinks: false,
            directory: descriptor,
            permit: permit
        )
        return FileByteSnapshot(data: result.data, baseline: result.baseline)
    }
}
