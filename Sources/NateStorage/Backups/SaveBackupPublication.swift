import Darwin
import Foundation
import NateCore

extension SaveBackupStore {
    /// 业务作用：以有界分块复制授权原文件，全部证据一致且强同步后才让原字节成为历史依赖。
    /// 参数说明:
    /// - url: 用户授权覆盖的原路径。
    /// - expected: 固定的原文件身份和摘要。
    /// - byteCount: 备份必须具有的精确长度。
    /// - authority: 本次保存可派生的单次发布范围。
    /// - permit: 发布前仍有效的请求权限。
    /// 返回：原字节持久化且身份、长度、摘要均确认；已有相同内容只复验而不重写。
    func persistOriginal(
        _ url: URL,
        expected: DiskBaseline,
        byteCount: Int64,
        authority: any FilePublicationScope,
        permit: @Sendable () -> Bool
    ) throws {
        let target = blobURL(expected.digest)
        if try regularFileExists(target) {
            try verifyBlob(expected.digest, byteCount: byteCount, permit: permit)
            return
        }
        _ = try trustedDirectory()
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw FileStorage.posix("无法建立保存备份临时内容")
        }
        var published = false
        defer {
            if !published {
                var held = stat()
                var path = stat()
                // 只移除本次独占建立的同一目录项，未知替换不能被临时清理顺带删除。
                if fstat(descriptor, &held) == 0, lstat(temporary.path, &path) == 0,
                    held.st_dev == path.st_dev, held.st_ino == path.st_ino
                {
                    Darwin.unlink(temporary.path)
                }
            }
            Darwin.close(descriptor)
        }
        let bytes = try FileStorage.readEvidence(
            url,
            collectBytes: false,
            maximumBytes: Int(byteCount),
            consume: {
                raw in
                var offset = 0
                while offset < raw.count {
                    guard permit() else {
                        throw CancellationError()
                    }
                    guard let base = raw.baseAddress else {
                        throw NateError.message("保存备份分块缺少可读取的原字节。")
                    }
                    let amount = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        raw.count - offset
                    )
                    if amount < 0 && errno == EINTR {
                        continue
                    }
                    guard amount > 0 else {
                        throw FileStorage.posix("保存备份原字节输出未完成")
                    }
                    offset += amount
                }
            },
            permit: permit
        )
        // 原文件可能在复制期间被外部更新，未通过同描述符复验的内容不能进入历史索引。
        guard bytes.baseline == expected, bytes.totalByteCount == byteCount else {
            throw NateError.message("复制保存备份期间原文件发生变化，覆盖已停止。")
        }
        try FileStorage.synchronize(descriptor)
        try authority.withAuthority {
            // 原字节先持久化并取得独立发布权；原文件的发布权仍保留给后续实际保存。
            try $0.publish {
                _ = try trustedDirectory()
                guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw FileStorage.posix("无法发布保存备份原字节")
                }
                published = true
                try synchronizeDirectory()
            }
        }
        var identity = stat()
        let result = try readPrivate(
            target,
            maximumBytes: Int(byteCount),
            collectBytes: false,
            permit: permit
        )
        guard fstat(descriptor, &identity) == 0,
            result.baseline.device == UInt64(UInt32(bitPattern: identity.st_dev)),
            result.baseline.inode == identity.st_ino,
            result.baseline.digest == expected.digest, result.totalByteCount == byteCount
        else {
            throw NateError.message("保存备份发布后证据不一致，原文件保持原状。")
        }
    }

    /// 业务作用：索引可靠发布后才删除无引用的受管理内容，异常记录和未知命名保持原状。
    /// 参数说明:
    /// - entries: 当前可靠历史的全部引用。
    /// - authority: 与父保存共享撤销的派生发布范围。
    /// - permit: 本次动作仍有效的权限。
    /// 返回：清理并同步目录；失败不会把未清理的字节说成已经回收。
    func collectUnreferenced(
        _ entries: [SavedFileBackup],
        authority: any FilePublicationScope,
        permit: @Sendable () -> Bool
    ) throws {
        try validateDependencies(entries, permit: permit)
        let retained = Set(entries.map(\.checksum))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= Self.entryLimit + 1024 else {
            throw NateError.message("保存备份目录项超过清理预算，现有内容保持原状。")
        }
        var candidates: [(URL, stat)] = []
        for name in names {
            guard permit() else {
                throw CancellationError()
            }
            let checksum = String(name.dropLast(7))
            let isBlob = name.hasSuffix(".backup") && validChecksum(checksum)
            let isPartial = name.hasSuffix(".partial") && UUID(uuidString: String(name.dropLast(8))) != nil
            guard (isBlob && !retained.contains(checksum)) || isPartial else {
                continue
            }
            let target = directory.appendingPathComponent(name)
            guard try regularFileExists(target), let metadata = try item(target) else {
                throw NateError.message("保存备份清理目标发生变化，现有内容保持原状。")
            }
            if isBlob {
                try verifyBlob(checksum, byteCount: metadata.st_size, permit: permit)
            }
            else if Date().timeIntervalSince1970 - Double(metadata.st_mtimespec.tv_sec) < 86_400 {
                continue
            }
            candidates.append((target, metadata))
        }
        // 先验证全部候选，发现损坏现场时不能在同一轮中提前删掉其它可用历史。
        for (target, expected) in candidates {
            try authority.withAuthority {
                try $0.publish {
                    _ = try trustedDirectory()
                    guard let current = try item(target), FileStorage.sameObservation(current, expected)
                    else {
                        throw NateError.message("保存备份清理前身份已经变化，保留该路径。")
                    }
                    guard Darwin.unlink(target.path) == 0 else {
                        throw FileStorage.posix("保存备份清理未完成")
                    }
                    try synchronizeDirectory()
                }
            }
        }
    }
}
