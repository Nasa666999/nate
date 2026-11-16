import CryptoKit
import Darwin
import Foundation
import NateCore

public struct DiskBaseline: Sendable, Codable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var digest: String
    public var resolvedPath: String
}

public struct LoadedFile: Sendable {
    public let url: URL
    public let text: String
    public let tree: PieceTree
    public let encoding: TextEncoding
    public let baseline: DiskBaseline
    public let originalBytes: Data
    public let inferred: Bool
    public let lineEnding: LineEnding
}

public struct FileDecodingFailure: Error, LocalizedError, Sendable {
    let reason: String
    public var errorDescription: String? {
        reason
    }
}

public enum FileStorage {
    /// 业务作用：记录真实身份与全部字节证据，同大小改写不能绕过冲突检测。
    /// 参数说明:
    /// - url: 用户目标路径。
    /// 返回：真实目标、文件身份和内容摘要。
    public static func baseline(_ url: URL) throws -> DiskBaseline {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw posix("无法读取原文件身份")
        }
        defer {
            Darwin.close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posix("无法读取原文件身份")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw NateError.message("只能将普通文件作为编辑和保存目标。")
        }
        var hasher = SHA256()
        var remaining = metadata.st_size
        var block = [UInt8](repeating: 0, count: 262_144)
        while remaining > 0 {
            let read = try block.withUnsafeMutableBytes {
                bytes -> Int in
                let amount = Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    min(bytes.count, Int(min(remaining, Int64(bytes.count))))
                )
                if amount < 0 && errno == EINTR {
                    return -1
                }
                guard amount > 0 else {
                    throw posix("原文件读取未完成")
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<amount]))
                return amount
            }
            if read > 0 {
                remaining -= Int64(read)
            }
        }
        var after = stat()
        var path = stat()
        // 摘要只证明这个描述符的固定内容，路径换文件或读取中改写都必须拒绝。
        guard fstat(descriptor, &after) == 0, stat(resolved.path, &path) == 0,
            sameObservation(metadata, after), sameObservation(after, path)
        else {
            throw NateError.message("获取磁盘证据期间文件发生变化。")
        }
        return DiskBaseline(
            device: UInt64(UInt32(bitPattern: metadata.st_dev)),
            inode: metadata.st_ino,
            digest: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            resolvedPath: resolved.path
        )
    }

    /// 业务作用：读取前后复验文件，防止将多个外部修订拼为同一缓冲区。
    /// 参数说明:
    /// - url: 待打开文件。
    /// - encoding: 可选的用户指定解释方式。
    /// - catalog: 注入的严格代码页映射。
    /// 返回：正文、原始字节与可靠基线；读取中变化时失败。
    public static func load(_ url: URL, encoding: TextEncoding? = nil, catalog: LegacyCodecCatalog? = nil)
        throws -> LoadedFile
    {
        let first = try baseline(url)
        let data = try Data(contentsOf: URL(fileURLWithPath: first.resolvedPath))
        let second = try baseline(url)
        guard first == second, digest(data) == first.digest else {
            throw NateError.message("读取期间文件发生变化，请重试。")
        }
        let decoded: (String, TextEncoding, Bool)
        do {
            decoded = try TextEncoding.detect(data, explicit: encoding, catalog: catalog)
        }
        catch {
            throw FileDecodingFailure(reason: error.localizedDescription)
        }
        return LoadedFile(
            url: url.standardizedFileURL,
            text: decoded.0,
            tree: PieceTree(decoded.0),
            encoding: decoded.1,
            baseline: second,
            originalBytes: data,
            inferred: decoded.2,
            lineEnding: LineEnding.detect(decoded.0)
        )
    }

    /// 业务作用：安全发布一个固定保存快照，不允许旧基线覆盖外部变更。
    /// 参数说明:
    /// - data: 已完成严格编码的文件字节。
    /// - url: 用户确认的目标。
    /// - expected: 已有文件必须匹配的基线；新建目标必须不存在。
    /// - permit: 发布前仍必须有效的请求权限。
    /// 返回：写入、同步与替换完成后的真实基线。
    public static func save(
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        guard permit() else {
            throw CancellationError()
        }
        let target =
            expected.map {
                URL(fileURLWithPath: $0.resolvedPath)
            } ?? url.standardizedFileURL
        // 符号链接仅写确认过的目标；删除或换目标都必须先重新授权。
        if let expected {
            guard try baseline(url) == expected else {
                throw NateError.message("外部冲突：磁盘身份或内容已经改变，自动保存已暂停。")
            }
            var metadata = stat()
            guard stat(target.path, &metadata) == 0 else {
                throw posix("无法复验原文件身份")
            }
            guard metadata.st_nlink <= 1 else {
                throw NateError.message("文件具有硬链接，安全替换会改变共享语义，请另存为。")
            }
            guard FileManager.default.isWritableFile(atPath: target.path) else {
                throw NateError.message("原文件不可写，恢复副本仍独立保存。")
            }
        }
        else if FileManager.default.fileExists(atPath: target.path) {
            throw NateError.message("保存目标已存在，必须先确认其当前内容。")
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".nate-\(UUID().uuidString)"
        )
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw posix("无法创建同目录临时文件")
        }
        var published = false
        defer {
            Darwin.close(fd)
            if !published {
                Darwin.unlink(temporary.path)
            }
        }
        try data.withUnsafeBytes {
            raw in
            var written = 0
            while written < raw.count {
                guard let base = raw.baseAddress else {
                    break
                }
                let amount = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if amount < 0 && errno == EINTR {
                    continue
                }
                guard amount > 0 else {
                    throw posix("文件输出未完成")
                }
                written += amount
            }
        }
        if expected != nil {
            var metadata = stat()
            guard stat(target.path, &metadata) == 0 else {
                throw posix("无法读取原文件权限")
            }
            guard fchmod(fd, metadata.st_mode & 0o7777) == 0 else {
                throw posix("无法保留文件权限")
            }
            // 元数据与 ACL 在发布前复制，原文件尚未被替换。
            guard copyfile(target.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw posix("无法保留文件元数据")
            }
        }
        try synchronize(fd)
        // 最后一次复验尽量缩小外部非协作写入的竞争窗口。
        if let expected {
            guard try baseline(url) == expected else {
                throw NateError.message("发布前检测到外部变化，保留本地正文并停止覆盖。")
            }
        }
        else {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw NateError.message("新建目标已被其他进程占用。")
            }
        }
        let flags: UInt32 = expected == nil ? UInt32(RENAME_EXCL) : 0
        // 取消只在发布前停止；替换已经发生后必须继续确认实际持久化阶段。
        guard permit() else {
            throw CancellationError()
        }
        guard renamex_np(temporary.path, target.path, flags) == 0 else {
            throw posix("无法发布文件替换")
        }
        published = true
        let directory = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else {
            throw NateError.message("内容已替换，但无法确认目录同步。")
        }
        defer {
            Darwin.close(directory)
        }
        guard fsync(directory) == 0 else {
            throw NateError.message("内容已替换，但目录同步失败，请检查磁盘实际状态。")
        }
        return try baseline(url)
    }

    /// 业务作用：在发布前请求文件系统与驱动器完成同步，不能静默降低保证。
    /// 参数说明:
    /// - fd: 已完成输出的文件描述符。
    /// 返回：文件同步和 F_FULLFSYNC 都成功；不支持时明确失败。
    static func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else {
            throw posix("文件同步失败")
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else {
            throw posix("目标不支持或未完成驱动器强同步")
        }
    }

    /// 业务作用：为恢复索引和文件证据生成稳定完整性校验。
    /// 参数说明:
    /// - data: 原始字节。
    /// 返回：SHA-256 十六进制字符串。
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// 业务作用：将系统失败保留为可理解的实际阶段说明。
    /// 参数说明:
    /// - stage: 失败发生阶段。
    /// 返回：带系统原因的错误。
    static func posix(_ stage: String) -> NateError {
        .message(stage + "：" + String(cString: strerror(errno)))
    }
}
