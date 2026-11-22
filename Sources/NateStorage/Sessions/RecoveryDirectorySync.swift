import Darwin
import Foundation
import NateCore

extension RecoveryStore {
    /// 业务作用：复用已有恢复内容仍须确认目录项持久化，先前未确认的目录同步不能沿字节相同被跳过。
    /// 参数说明:
    /// - includingChunks: 正文索引需要分块目录，纯侧栏只确认恢复根与其父目录。
    /// - deadline: 所属完整恢复动作的共同截止。
    /// 返回：已确认的无链接容器全部完成目录同步；失权、目录变化或同步失败不发布新索引。
    func synchronizeRecoveryDirectories(
        includingChunks: Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        guard let budget = storageBudget else {
            throw NateError.message("恢复目录同步缺少当前动作资格，未发布新入口。")
        }
        let allowed: @Sendable () -> Bool = {
            budget.allowed && !Task.isCancelled && .now < deadline
        }
        progress(.synchronizingDependencies)
        try budget.verifyContainers(store: self)
        var containers: [URL] = []
        if includingChunks, try recoveryChunksExist() {
            containers.append(chunksDirectory)
        }
        containers.append(directory)
        containers.append(directory.deletingLastPathComponent())
        for container in containers {
            try checkRecoveryBudget(deadline, permit: allowed)
            guard let expected = try storageDirectoryIdentity(container) else {
                throw NateError.message("恢复依赖目录缺失，未确认新的恢复入口。")
            }
            let descriptor = try DirectoryContents.openDirectory(
                root: URL(fileURLWithPath: "/", isDirectory: true),
                directory: container,
                permit: allowed
            )
            defer {
                Darwin.close(descriptor)
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                UInt64(UInt32(bitPattern: metadata.st_dev)) == expected.device,
                UInt64(metadata.st_ino) == expected.inode
            else {
                throw NateError.message("恢复目录读取权与原容器身份不一致，未发布新入口。")
            }
            // 先确认分块名与清单名，再确认恢复根在父目录中的入口；相同字节不代表先前目录同步已经完成。
            try checkRecoveryBudget(deadline, permit: allowed)
            guard fsync(descriptor) == 0 else {
                throw NateError.message("恢复依赖目录同步未确认，现有恢复入口继续保留。")
            }
            guard try storageDirectoryIdentity(container) == expected else {
                throw NateError.message("恢复目录同步期间容器发生变化，未确认新的恢复入口。")
            }
            try budget.verifyContainers(store: self)
        }
        try checkRecoveryBudget(deadline, permit: allowed)
    }
}
