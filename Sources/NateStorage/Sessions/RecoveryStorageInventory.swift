import Darwin
import Foundation
import NateCore

struct RecoveryStorageIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct RecoveryStorageInventory: Sendable {
    var bytes: Int64 = 0
    var files: [Data: Int64] = [:]
    var directories: [Data: RecoveryStorageIdentity] = [:]
}

extension RecoveryStore {
    /// 业务作用：有界统计恢复根目录和分块目录的全部普通文件，未知文件同样占用容量。
    /// 参数说明:
    /// - deadline: 本次统计与后续恢复操作共用的截止。
    /// - permit: 当前统计仍有效的执行资格。
    /// 返回：原字节路径对应的逻辑大小及目录身份；链接、未知子目录、变化或超量时拒绝统计。
    func storageInventory(
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> RecoveryStorageInventory {
        try checkRecoveryBudget(deadline, permit: permit)
        _ = try recoveryParent(directory.appendingPathComponent("session.json"))
        var inventory = RecoveryStorageInventory()
        guard let root = try storageDirectoryIdentity(directory) else {
            return inventory
        }
        inventory.directories[Data(directory.path.utf8)] = root
        var pending = [directory]
        var entries = 0
        while let current = pending.popLast() {
            try checkRecoveryBudget(deadline, permit: permit)
            let files = try FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil
            )
            guard files.count <= 131_072 - entries else {
                throw NateError.message("恢复目录条目超过容量统计预算，现有内容保留。")
            }
            entries += files.count
            for url in files {
                try checkRecoveryBudget(deadline, permit: permit)
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let key = Data(url.path.utf8)
                if metadata.st_mode & S_IFMT == S_IFDIR {
                    guard current.path == directory.path, url.lastPathComponent == "chunks" else {
                        throw NateError.message("恢复目录含未知子目录，容量无法完整确认，未写入新内容。")
                    }
                    inventory.directories[key] = RecoveryStorageIdentity(
                        device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                        inode: UInt64(metadata.st_ino)
                    )
                    pending.append(url)
                }
                else {
                    // 链接不是当前实例可独立控制的普通恢复内容，不能沿外部文件大小授权新写入。
                    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                        metadata.st_size >= 0, metadata.st_size <= Int64.max - inventory.bytes
                    else {
                        throw NateError.message("恢复目录含链接、特殊文件或不可解释长度，现有内容保留。")
                    }
                    inventory.bytes += metadata.st_size
                    inventory.files[key] = metadata.st_size
                }
            }
        }
        // 目录枚举不能跨越一次根或分块目录替换，统计与后续写入必须属于相同容器。
        for (key, expected) in inventory.directories {
            let url = URL(fileURLWithPath: String(decoding: key, as: UTF8.self), isDirectory: true)
            guard try storageDirectoryIdentity(url) == expected else {
                throw NateError.message("恢复容量统计期间目录发生变化，未写入新内容。")
            }
        }
        try checkRecoveryBudget(deadline, permit: permit)
        return inventory
    }

    /// 业务作用：容量资格绑定目录项自身的设备与 inode，不把同路径下的新目录当成原容器。
    /// 参数说明:
    /// - url: 当前固定恢复根或分块目录。
    /// 返回：真实普通目录身份；真正缺失为空，链接或其它类型拒绝。
    func storageDirectoryIdentity(_ url: URL) throws -> RecoveryStorageIdentity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path
        else {
            throw NateError.message("恢复容量涉及的目录不是原有无链接容器，未写入新内容。")
        }
        return RecoveryStorageIdentity(
            device: UInt64(UInt32(bitPattern: metadata.st_dev)),
            inode: UInt64(metadata.st_ino)
        )
    }
}
