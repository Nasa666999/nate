import Foundation
import NateCore
import Darwin

extension RecoveryStore {
    /// 业务作用：缺失与链接损坏必须区分，不能把失效链接当成空索引后覆盖外部路径。
    /// 参数说明:
    /// - url: 当前目录内的索引、记录或内容文件。
    /// 返回：普通文件存在时为真，真正缺失时为假；其它类型和权限错误均拒绝。
    func recoveryFileExists(_ url: URL) throws -> Bool {
        _ = try recoveryParent(url)
        guard let mode = try recoveryItemMode(url) else {
            return false
        }
        guard mode & S_IFMT == S_IFREG else {
            throw NateError.message("恢复记录不是普通文件，现有路径保持原状。")
        }
        return true
    }

    /// 业务作用：分块子目录不能被链接或普通文件代替，清理前同样必须验证。
    /// 参数说明: 无。
    /// 返回：可信分块目录存在时为真；缺失时为假，其它情况拒绝。
    func recoveryChunksExist() throws -> Bool {
        _ = try recoveryParent(chunksDirectory)
        guard let mode = try recoveryItemMode(chunksDirectory) else {
            return false
        }
        guard mode & S_IFMT == S_IFDIR else {
            throw NateError.message("恢复分块目录不是可信目录，现有路径保持原状。")
        }
        return true
    }

    /// 业务作用：读取目录项本身的类型，悬空符号链接也必须保留为错误现场。
    /// 参数说明:
    /// - url: 当前恢复目录内的精确路径。
    /// 返回：目录项本身的类型位；仅真正不存在返回空，其它失败向上传递。
    private func recoveryItemMode(_ url: URL) throws -> mode_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return metadata.st_mode
    }

    /// 业务作用：所有恢复访问限于固定根目录或分块子目录，路径改向时失去访问资格。
    /// 参数说明:
    /// - url: 待访问文件或分块目录。
    /// 返回：可信父目录；存在符号链接改向时拒绝。
    func recoveryParent(_ url: URL) throws -> URL {
        try FileStorage.validateFileURL(directory)
        try FileStorage.validateFileURL(url)
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path == directory.path || parent.path == chunksDirectory.path,
            parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path
        else {
            throw NateError.message("恢复目录被链接改向，现有路径保持原状。")
        }
        return parent
    }

    /// 业务作用：私有恢复依赖必须属于原目录，不能把链接到外部可变文件的路径当成持久化分块。
    /// 参数说明:
    /// - url: 根索引、记录或内容分块的固定路径。
    /// - maximumBytes: 读取前必须满足的文件大小预算。
    /// - collectBytes: 是否保留内容；仅验证时流式计算摘要。
    /// - permit: 当前读取请求权限。
    /// 返回：未跟随符号链接的原字节与证据；路径改向或链接记录均拒绝。
    func readRecoveryFile(
        _ url: URL,
        maximumBytes: Int,
        collectBytes: Bool = true,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> FileReadEvidence {
        // 恢复根目录在建立存储时已固定；之后子目录改向不能把私有依赖迁移到外部路径。
        let parent = try recoveryParent(url)
        let result = try FileStorage.readEvidence(
            url,
            collectBytes: collectBytes,
            maximumBytes: maximumBytes,
            resolvingLinks: false,
            permit: permit
        )
        guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else {
            throw NateError.message("读取期间恢复目录发生改向。")
        }
        return result
    }
}
