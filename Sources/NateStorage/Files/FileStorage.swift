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
    /// - permit: 完整证据读取的请求权限。
    /// 返回：真实目标、文件身份和内容摘要。
    public static func baseline(
        _ url: URL,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        try readEvidence(url, collectBytes: false, maximumBytes: Int.max, permit: permit).baseline
    }

    /// 业务作用：固定描述符读取并复验路径，防止将多个外部修订拼为同一缓冲区。
    /// 参数说明:
    /// - url: 待打开文件。
    /// - encoding: 可选的用户指定解释方式。
    /// - catalog: 注入的严格代码页映射。
    /// - maximumBytes: 原字节读取上限，超过时在分配完整正文前拒绝。
    /// - permit: 等待与读取期间有效的请求权限。
    /// 返回：正文、原始字节与可靠基线；读取中变化时失败。
    public static func load(
        _ url: URL,
        encoding: TextEncoding? = nil,
        catalog: LegacyCodecCatalog? = nil,
        maximumBytes: Int = Int.max,
        permit: @Sendable () -> Bool = {
            true
        }
    )
        throws -> LoadedFile
    {
        let bytes = try readData(url, maximumBytes: maximumBytes, permit: permit)
        let data = bytes.data
        let baseline = bytes.baseline
        let decoded: (String, TextEncoding, Bool)
        guard permit() else {
            throw CancellationError()
        }
        do {
            decoded = try TextEncoding.detect(data, explicit: encoding, catalog: catalog)
        }
        catch {
            throw FileDecodingFailure(reason: error.localizedDescription)
        }
        guard permit() else {
            throw CancellationError()
        }
        let tree = PieceTree(decoded.0)
        let ending = LineEnding.detect(decoded.0)
        guard permit() else {
            throw CancellationError()
        }
        return LoadedFile(
            url: url.standardizedFileURL,
            text: decoded.0,
            tree: tree,
            encoding: decoded.1,
            baseline: baseline,
            originalBytes: data,
            inferred: decoded.2,
            lineEnding: ending
        )
    }

    /// 业务作用：安全发布一个固定保存快照，不允许旧基线覆盖外部变更。
    /// 参数说明:
    /// - data: 已完成严格编码的文件字节。
    /// - url: 用户确认的目标。
    /// - expected: 已有文件必须匹配的基线；新建目标必须不存在。
    /// - permit: 发布前仍必须有效的请求权限。
    /// - authority: 单次发布权，防止取消与原子替换之间出现不确定的授权顺序。
    /// - observe: 实际执行阶段的只读观察入口。
    /// 返回：写入、同步与替换完成后的真实基线。
    public static func save(
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = {
            true
        },
        authority: (any FilePublicationAuthority)? = nil,
        observe: FileSaveObservation = {
            _ in
        }
    ) throws -> DiskBaseline {
        guard permit() else {
            throw CancellationError()
        }
        try validateFileURL(url)
        observe(.checkingBaseline)
        let target =
            expected.map {
                URL(fileURLWithPath: $0.resolvedPath)
            }
            ?? url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent)
        // 新目标尚不存在时不能依赖整条路径解析；先固定已有父目录，避免别名在发布前后产生不同路径证据。
        let publishedPath = target.path
        let expectedDigest = digest(data)
        // 符号链接仅写确认过的目标；删除或换目标都必须先重新授权。
        if let expected {
            guard try baseline(url, permit: permit) == expected else {
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
        // 目录读取可能等待系统隐私授权，必须在替换原文件之前取得同步描述符，不能先产生未确认覆盖。
        observe(.preparingDirectory)
        let parent = target.deletingLastPathComponent()
        // 用户目录允许合法链接别名，实际描述符身份与发布前路径复验共同约束写入目标。
        let directory = Darwin.open(
            parent.resolvingSymlinksInPath().standardizedFileURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY
        )
        guard directory >= 0 else {
            throw posix("无法取得目标目录同步权限，原文件未覆盖")
        }
        defer {
            Darwin.close(directory)
        }
        var directoryIdentity = stat()
        guard fstat(directory, &directoryIdentity) == 0 else {
            throw posix("无法确认目标目录身份，原文件未覆盖")
        }
        guard permit() else {
            throw CancellationError()
        }
        let temporary = ".nate-\(UUID().uuidString)"
        let fd = Darwin.openat(
            directory,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else {
            throw posix("无法创建同目录临时文件")
        }
        observe(.writingTemporary)
        var published = false
        defer {
            if !published {
                var held = stat()
                var path = stat()
                // 目录移动后仍只清理本次描述符对应的临时项，不能按旧绝对路径删除未知的新文件。
                if fstat(fd, &held) == 0,
                    fstatat(directory, temporary, &path, AT_SYMLINK_NOFOLLOW) == 0,
                    held.st_dev == path.st_dev, held.st_ino == path.st_ino
                {
                    Darwin.unlinkat(directory, temporary, 0)
                }
            }
            Darwin.close(fd)
        }
        try data.withUnsafeBytes {
            raw in
            var written = 0
            while written < raw.count {
                guard permit() else {
                    throw CancellationError()
                }
                guard let base = raw.baseAddress else {
                    break
                }
                let amount = Darwin.write(fd, base.advanced(by: written), min(262_144, raw.count - written))
                if amount < 0 && errno == EINTR {
                    continue
                }
                guard amount > 0 else {
                    throw posix("文件输出未完成")
                }
                written += amount
            }
        }
        if let expected {
            observe(.preservingMetadata)
            let source = Darwin.openat(
                directory,
                target.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
            )
            guard source >= 0 else {
                throw posix("无法读取原文件元数据")
            }
            defer {
                Darwin.close(source)
            }
            var metadata = stat()
            // 元数据来源必须仍是授权原文件，不跟随发布前临时改向的链接。
            guard fstat(source, &metadata) == 0,
                UInt64(UInt32(bitPattern: metadata.st_dev)) == expected.device,
                metadata.st_ino == expected.inode, metadata.st_nlink <= 1
            else {
                throw NateError.message("原文件元数据身份发生外部变化，覆盖已停止。")
            }
            guard fchmod(fd, metadata.st_mode & 0o7777) == 0 else {
                throw posix("无法保留文件权限")
            }
            // 元数据与 ACL 在发布前复制，原文件尚未被替换。
            guard fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw posix("无法保留文件元数据")
            }
        }
        guard permit() else {
            throw CancellationError()
        }
        observe(.synchronizingFile)
        try synchronize(fd)
        // 最后一次复验尽量缩小外部非协作写入的竞争窗口。
        observe(.revalidatingBaseline)
        if let expected {
            guard try baseline(url, permit: permit) == expected else {
                throw NateError.message("发布前检测到外部变化，保留本地正文并停止覆盖。")
            }
        }
        else {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw NateError.message("新建目标已被其他进程占用。")
            }
        }
        let flags: UInt32 = expected == nil ? UInt32(RENAME_EXCL) : 0
        var currentDirectory = stat()
        // 同步描述符与即将发布的路径必须仍属于同一目录，目录被替换后不能继续沿用旧同步权威。
        guard stat(parent.path, &currentDirectory) == 0,
            currentDirectory.st_dev == directoryIdentity.st_dev,
            currentDirectory.st_ino == directoryIdentity.st_ino
        else {
            throw NateError.message("发布前目标目录发生外部变化，原文件未覆盖。")
        }
        var prepared = stat()
        var temporaryPath = stat()
        // 发布名称必须仍指向本次输出描述符，未知替换或链接不能借用当前保存的发布权限。
        guard fstat(fd, &prepared) == 0,
            fstatat(directory, temporary, &temporaryPath, AT_SYMLINK_NOFOLLOW) == 0,
            temporaryPath.st_mode & S_IFMT == S_IFREG, temporaryPath.st_nlink == 1,
            sameObservation(prepared, temporaryPath)
        else {
            throw NateError.message("发布前临时内容身份发生外部变化，原文件未覆盖。")
        }
        // 取消只在发布前停止；替换已经发生后必须继续确认实际持久化阶段。
        guard permit() else {
            throw CancellationError()
        }
        // 发布权只使用一次；取得权威后即使收到取消，也必须继续确认实际替换和同步结果。
        if let authority {
            try authority.publish {
                try publishReplacement(
                    temporary,
                    to: target.lastPathComponent,
                    directory: directory,
                    flags: flags,
                    observe: observe
                )
            }
        }
        else {
            try publishReplacement(
                temporary,
                to: target.lastPathComponent,
                directory: directory,
                flags: flags,
                observe: observe
            )
        }
        published = true
        observe(.published)
        observe(.synchronizingDirectory)
        guard fsync(directory) == 0 else {
            throw NateError.message("内容已替换，但目录同步失败，请检查磁盘实际状态。")
        }
        observe(.confirmingSavedFile)
        let result = try baseline(url)
        var publishedMetadata = stat()
        // 写后证据必须属于本次替换的描述符与固定字节，否则不能把外部正文冒认为本次保存点。
        guard fstat(fd, &publishedMetadata) == 0,
            result.device == UInt64(UInt32(bitPattern: publishedMetadata.st_dev)),
            result.inode == publishedMetadata.st_ino,
            result.resolvedPath == publishedPath,
            result.digest == expectedDigest
        else {
            throw NateError.message("内容已发布，但确认时检测到外部变化；本地正文保留，原文件保存尚未确认。")
        }
        return result
    }

    /// 业务作用：取得发布权后只执行一次原子替换，阶段观察不会把待执行动作保存到同步范围外。
    /// 参数说明:
    /// - temporary: 已完成编码与强同步的同目录临时名称。
    /// - target: 已复验的原目标名称。
    /// - directory: 发布前取得并确认身份的共同父目录描述符。
    /// - flags: 新建目标的排他发布规则。
    /// - observe: 实际阶段观察入口。
    /// 返回：原子替换成功；失败保留实际错误，由调用方处理临时文件和未确认状态。
    static func publishReplacement(
        _ temporary: String,
        to target: String,
        directory: Int32,
        flags: UInt32,
        observe: FileSaveObservation
    ) throws {
        // 完整且已同步的内容在此一次切换为目标，后续只确认持久化而不再更改正文。
        observe(.publishing)
        guard renameatx_np(directory, temporary, directory, target, flags) == 0 else {
            throw posix("无法发布文件替换")
        }
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
