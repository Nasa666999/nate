import Darwin
import Foundation

public struct InstanceRequest: Sendable {
    public let id: UUID
    public let data: Data
}

public struct InstanceInbox: Sendable {
    public static let notification = Notification.Name("io.github.Nasa666999.nate.open-request")
    let directory: URL

    /// 业务作用：跨进程请求只进入当前用户私有目录，通知仅承担唤醒职责。
    /// 参数说明:
    /// - directory: 应用支持目录中的请求目录。
    /// 返回：受所有者与目录类型约束的请求入口；符号链接或其他所有者被拒绝。
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(), chmod(directory.path, 0o700) == 0
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.directory = directory
    }

    /// 业务作用：先完整写入请求，再原子发布可见文件，主实例启动期间也不会丢失路径。
    /// 参数说明:
    /// - data: 已验证并规范化的启动参数，最多 1 MB。
    /// 返回：请求身份；写入失败不会出现半份可消费请求。
    @discardableResult
    public func enqueue(_ data: Data) throws -> UUID {
        guard data.count <= 1_048_576 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let id = UUID()
        let pending = directory.appendingPathComponent("pending-" + id.uuidString)
        let target = directory.appendingPathComponent(id.uuidString + ".json")
        let fd = Darwin.open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            Darwin.close(fd)
            Darwin.unlink(pending.path)
        }
        try data.withUnsafeBytes {
            bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else {
                    break
                }
                let amount = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR {
                    continue
                }
                guard amount > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += amount
            }
        }
        guard fsync(fd) == 0, renamex_np(pending.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return id
    }

    /// 业务作用：有界读取完整发布的请求，不消费仍在写入的临时文件。
    /// 参数说明: 无。
    /// 返回：最多 256 个经文件类型和容量检查的请求。
    public func requests() throws -> [InstanceRequest] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        var result: [InstanceRequest] = []
        for url in urls.sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            guard url.pathExtension == "json",
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else {
                continue
            }
            let properties = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                let size = properties.fileSize, size <= 1_048_576
            else {
                continue
            }
            result.append(InstanceRequest(id: id, data: try Data(contentsOf: url)))
            if result.count == 256 {
                break
            }
        }
        return result
    }

    /// 业务作用：请求处理结束后仅移除对应的精确发布文件。
    /// 参数说明:
    /// - id: 已处理的请求身份。
    /// 返回：后续扫描不再重复打开；失败保留请求供再次处理。
    public func complete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
}
