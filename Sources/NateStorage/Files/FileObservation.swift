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
    /// 业务作用：确认摘要读取前后仍是同一文件状态，不以相同长度替代内容时序证据。
    /// 参数说明:
    /// - first: 读取前身份与时间。
    /// - second: 读取后身份与时间。
    /// 返回：身份、长度及纳秒状态时间均相同才允许使用摘要。
    static func sameObservation(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    /// 业务作用：持续观察只检查轻量元数据，发生变化后再读取完整内容证据。
    /// 参数说明:
    /// - url: 当前绑定的原始路径，符号链接每次重新解析。
    /// 返回：包含纳秒修改与状态时间的观察标记；缺失目标明确失败。
    public static func stamp(_ url: URL) throws -> FileStamp {
        try validateFileURL(url)
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
