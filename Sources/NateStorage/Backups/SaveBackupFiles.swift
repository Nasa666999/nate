import Darwin
import Foundation
import NateCore
import os

final class SaveBackupCache: Sendable {
    let stamps = OSAllocatedUnfairLock(initialState: [String: FileStamp]())
}

extension SaveBackupStore {
    /// 业务作用：跨线程和实例串行化备份索引事务，锁等待可取消且不会无限占用原文件通道。
    /// 参数说明:
    /// - create: 是否允许首次建立私有备份目录。
    /// - permit: 原保存或浏览请求仍有效的权限。
    /// - operation: 持锁期间同步完成的索引和原字节动作。
    /// 返回：实际事务结果；目录或锁身份不可靠时拒绝访问。
    func withDirectoryLock<Value>(
        create: Bool,
        permit: @Sendable () -> Bool,
        operation: () throws -> Value
    ) throws -> Value {
        guard permit() else {
            throw CancellationError()
        }
        if try item(directory) == nil {
            guard create else {
                return try operation()
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // 新目录本身也必须可从父目录可靠找到，不能只同步目录内的后续记录。
            let parent = Darwin.open(
                directory.deletingLastPathComponent().path,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            guard parent >= 0 else {
                throw FileStorage.posix("无法确认保存备份父目录")
            }
            defer {
                Darwin.close(parent)
            }
            guard fsync(parent) == 0 else {
                throw FileStorage.posix("保存备份父目录同步未完成")
            }
        }
        let original = try trustedDirectory()
        let lockURL = directory.appendingPathComponent(".lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw FileStorage.posix("无法打开保存备份锁")
        }
        defer {
            Darwin.close(descriptor)
        }
        var lockIdentity = stat()
        guard fstat(descriptor, &lockIdentity) == 0, lockIdentity.st_mode & S_IFMT == S_IFREG,
            lockIdentity.st_nlink == 1, lockIdentity.st_uid == getuid()
        else {
            throw NateError.message("保存备份锁身份不可靠，原文件保持原状。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw FileStorage.posix("无法取得保存备份锁")
            }
            guard permit() else {
                throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
                throw NateError.message("保存备份仍被另一个动作使用，原文件保持原状。")
            }
            usleep(10_000)
        }
        defer {
            flock(descriptor, LOCK_UN)
        }
        let current = try trustedDirectory()
        let lockPath = try item(lockURL)
        guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
            lockPath?.st_dev == lockIdentity.st_dev, lockPath?.st_ino == lockIdentity.st_ino,
            permit()
        else {
            throw NateError.message("等待期间保存备份目录或权限发生变化，原文件保持原状。")
        }
        let result = try operation()
        let after = try trustedDirectory()
        guard after.st_dev == original.st_dev, after.st_ino == original.st_ino else {
            throw NateError.message("保存备份目录发生替换，原文件保存尚未获准。")
        }
        return result
    }

    /// 业务作用：拒绝被链接、替换为其它类型或向其它用户开放的私有备份目录。
    /// 参数说明: 无。
    /// 返回：当前可信目录身份；不自动改动异常路径的权限或内容。
    func trustedDirectory() throws -> stat {
        guard let metadata = try item(directory), metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
            directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path
        else {
            throw NateError.message("保存备份目录必须是当前用户私有的真实目录，现有记录保持原状。")
        }
        return metadata
    }

    /// 业务作用：区分真实缺失与悬空链接，不把异常记录当作可以新建的空路径。
    /// 参数说明:
    /// - url: 当前备份目录内的精确路径或目录本身。
    /// 返回：不跟随链接的目录项身份，只有 ENOENT 表示缺失。
    func item(_ url: URL) throws -> stat? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw FileStorage.posix("无法观察保存备份路径")
        }
        return metadata
    }

    /// 业务作用：备份内容和索引只接受私有普通文件，不跟随链接或共享硬链接。
    /// 参数说明:
    /// - url: 受管理的完整记录路径。
    /// 返回：真实缺失时为假；存在异常类型或身份时抛错。
    func regularFileExists(_ url: URL) throws -> Bool {
        guard let metadata = try item(url) else {
            return false
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else {
            throw NateError.message("保存备份记录不是私有普通文件，现有内容保持原状。")
        }
        return true
    }

    /// 业务作用：以不跟随链接的精确证据读取私有历史，读取前后同时确认根目录没有改向。
    /// 参数说明:
    /// - url: 当前根目录内的精确记录。
    /// - maximumBytes: 读取的最大字节数。
    /// - collectBytes: 是否保留正文，纯验证使用流式摘要。
    /// - permit: 当前动作权限。
    /// 返回：长度预算内的原字节和身份，失败不返回部分内容。
    func readPrivate(
        _ url: URL,
        maximumBytes: Int,
        collectBytes: Bool = true,
        permit: @Sendable () -> Bool
    ) throws -> FileReadEvidence {
        let before = try trustedDirectory()
        guard url.deletingLastPathComponent() == directory, try regularFileExists(url) else {
            throw NateError.message("保存备份依赖缺失或越过私有目录。")
        }
        let bytes = try FileStorage.readEvidence(
            url,
            collectBytes: collectBytes,
            maximumBytes: maximumBytes,
            resolvingLinks: false,
            permit: permit
        )
        let after = try trustedDirectory()
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw NateError.message("读取期间保存备份目录发生变化。")
        }
        return bytes
    }

    /// 业务作用：根据固定内容摘要定位去重原字节，不在受管理文件名中解释原路径。
    /// 参数说明:
    /// - checksum: 已校验的 SHA-256 小写十六进制。
    /// 返回：当前私有目录内的原字节文件。
    func blobURL(_ checksum: String) -> URL {
        directory.appendingPathComponent(checksum + ".backup")
    }

    /// 业务作用：索引路径及内容身份必须可验证，未知格式和损坏记录不能被空历史覆盖。
    /// 参数说明:
    /// - permit: 当前动作权限。
    /// 返回：已校验的有界索引及其保存基线；只有真正缺失才返回空历史。
    func readIndex(permit: @Sendable () -> Bool) throws -> (index: SaveBackupIndex, bytes: FileReadEvidence?)
    {
        let target = directory.appendingPathComponent("index.json")
        guard try regularFileExists(target) else {
            return (SaveBackupIndex(entries: []), nil)
        }
        let bytes = try readPrivate(target, maximumBytes: Self.metadataLimit, permit: permit)
        let index = try JSONDecoder().decode(SaveBackupIndex.self, from: bytes.data)
        guard index.format == 1, index.entries.count <= Self.entryLimit,
            Set(index.entries.map(\.id)).count == index.entries.count
        else {
            throw NateError.message("保存备份索引格式、数量或身份不符合要求，现有记录保持原状。")
        }
        var lengths: [String: Int64] = [:]
        for entry in index.entries {
            guard validChecksum(entry.targetKey), validChecksum(entry.checksum),
                entry.originalPath.hasPrefix("/"), !entry.originalPath.contains("\0"),
                FileStorage.digest(Data(entry.originalPath.utf8)) == entry.targetKey,
                entry.created.timeIntervalSince1970.isFinite,
                (0...1_099_511_627_776).contains(entry.byteCount),
                lengths[entry.checksum] == nil || lengths[entry.checksum] == entry.byteCount
            else {
                throw NateError.message("保存备份索引包含不可靠的路径、长度或内容身份。")
            }
            lengths[entry.checksum] = entry.byteCount
        }
        return (index, bytes)
    }

    /// 业务作用：管理命名只接受完整摘要，不将任意目录项纳入清理范围。
    /// 参数说明:
    /// - value: 待解释的内容身份。
    /// 返回：恰好 64 个小写十六进制字节时为真。
    func validChecksum(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    /// 业务作用：在索引变更或清理前复验全部依赖，稳定身份缓存只减少重复摘要而不持有正文。
    /// 参数说明:
    /// - entries: 当前可靠历史引用。
    /// - permit: 当前动作权限。
    /// 返回：所有原字节仍与声明一致，缺失或变化时保留整个索引。
    func validateDependencies(_ entries: [SavedFileBackup], permit: @Sendable () -> Bool) throws {
        var seen: Set<String> = []
        for entry in entries where seen.insert(entry.checksum).inserted {
            try verifyBlob(entry.checksum, byteCount: entry.byteCount, permit: permit)
        }
    }

    /// 业务作用：只在内容身份与纳秒观察均稳定时复用验证结论，改变过的文件必须重新计算摘要。
    /// 参数说明:
    /// - checksum: 预期原字节摘要。
    /// - byteCount: 精确字节长度。
    /// - permit: 当前动作权限。
    /// 返回：内容完整时继续；缓存最多保留 4096 个轻量观察，不保留文件正文。
    func verifyBlob(_ checksum: String, byteCount: Int64, permit: @Sendable () -> Bool) throws {
        guard permit() else {
            throw CancellationError()
        }
        let target = blobURL(checksum)
        guard try regularFileExists(target) else {
            throw NateError.message("保存备份缺少索引引用的原字节。")
        }
        let before = try FileStorage.stamp(target)
        guard before.size == byteCount else {
            throw NateError.message("保存备份长度不符合索引。")
        }
        if cache.stamps.withLock({
            $0[checksum]
        }) == before {
            return
        }
        let bytes = try readPrivate(
            target,
            maximumBytes: Int(byteCount),
            collectBytes: false,
            permit: permit
        )
        guard bytes.baseline.digest == checksum, bytes.totalByteCount == byteCount,
            try FileStorage.stamp(target) == before
        else {
            throw NateError.message("保存备份原字节校验失败，现有记录保持原状。")
        }
        cache.stamps.withLock {
            if $0.count >= 4096 {
                $0.removeAll(keepingCapacity: true)
            }
            $0[checksum] = before
        }
    }

    /// 业务作用：确认备份目录项变化已经同步，不能只把原字节写完就宣称历史可恢复。
    /// 参数说明: 无。
    /// 返回：目录同步成功；失败由保存请求显示并阻止原文件覆盖。
    func synchronizeDirectory() throws {
        _ = try trustedDirectory()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw FileStorage.posix("无法打开保存备份目录")
        }
        defer {
            Darwin.close(descriptor)
        }
        guard fsync(descriptor) == 0 else {
            throw FileStorage.posix("保存备份目录同步未完成")
        }
    }
}
