import Darwin
import Foundation
import NateCore

public struct FileStamp: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let resolvedPath: String
}

extension FileStorage {
    /// 业务作用：持续观察只检查轻量元数据，发生变化后再读取完整内容证据。
    /// 参数说明:
    /// - url: 当前绑定的原始路径，符号链接每次重新解析。
    /// 返回：包含纳秒修改与状态时间的观察标记；缺失目标明确失败。
    public static func stamp(_ url: URL) throws -> FileStamp {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var value = stat()
        guard stat(resolved.path, &value) == 0 else {
            throw posix("无法观察原文件")
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw NateError.message("观察目标已经不是普通文件。")
        }
        return FileStamp(
            device: value.st_dev,
            inode: value.st_ino,
            size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanos: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec,
            changedNanos: value.st_ctimespec.tv_nsec,
            resolvedPath: resolved.path
        )
    }
}
