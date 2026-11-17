import CryptoKit
import Darwin
import Foundation
import NateCore

public struct FileByteSnapshot: Sendable {
    public let data: Data
    public let baseline: DiskBaseline
}

public struct FileByteSample: Sendable {
    public let data: Data
    public let totalByteCount: Int64
}

struct FileReadEvidence {
    let data: Data
    let baseline: DiskBaseline
    let totalByteCount: Int64
}

extension FileStorage {
    /// 业务作用：完整原始字节与磁盘基线由同一个文件描述符产生，资源解析不能冒用后续修订的基线。
    /// 参数说明:
    /// - url: 请求读取的目标。
    /// - maximumBytes: 完整文件允许的字节预算，超限在正文分配前拒绝。
    /// - permit: 读取过程中有效的请求权限。
    /// 返回：原始字节及其精确证据；变化、取消或超限均不发布部分正文。
    public static func readData(
        _ url: URL,
        maximumBytes: Int = Int.max,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> FileByteSnapshot {
        let evidence = try readEvidence(url, collectBytes: true, maximumBytes: maximumBytes, permit: permit)
        return FileByteSnapshot(data: evidence.data, baseline: evidence.baseline)
    }

    /// 业务作用：只保留字节预览所需前缀，同时用有界流式读取确认整个原文件未改变。
    /// 参数说明:
    /// - url: 待展示原字节的目标。
    /// - maximumBytes: 最多保留的前缀字节数。
    /// - permit: 请求权限。
    /// 返回：稳定原文件的有界前缀与真实总长度，不作为可写文档的保存基线。
    public static func readSample(
        _ url: URL,
        maximumBytes: Int,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> FileByteSample {
        guard maximumBytes >= 0 else {
            throw NateError.message("字节预览预算无效。")
        }
        let evidence = try readEvidence(
            url,
            collectBytes: true,
            maximumBytes: Int.max,
            maximumCaptureBytes: maximumBytes,
            permit: permit
        )
        return FileByteSample(data: evidence.data, totalByteCount: evidence.totalByteCount)
    }

    /// 业务作用：以单次流式读取同时确认身份、摘要和可选正文，观察证据时不复制整个文件。
    /// 参数说明:
    /// - url: 原请求路径。
    /// - collectBytes: 是否保留完整原始正文。
    /// - maximumBytes: 文件字节预算。
    /// - maximumCaptureBytes: 最多保留的原字节前缀，摘要仍涵盖完整文件。
    /// - resolvingLinks: 用户原文件可解析符号链接；私有恢复记录直接拒绝链接。
    /// - consume: 同步分块接收者，默认忽略；用于有限内存复制，不得保留块内指针。
    /// - permit: 请求仍有效的权限。
    /// 返回：精确基线和可选正文；任一身份或时间观察变化时失败。
    static func readEvidence(
        _ url: URL,
        collectBytes: Bool,
        maximumBytes: Int,
        maximumCaptureBytes: Int = Int.max,
        resolvingLinks: Bool = true,
        consume: (UnsafeRawBufferPointer) throws -> Void = {
            _ in
        },
        permit: @Sendable () -> Bool
    ) throws -> FileReadEvidence {
        guard maximumBytes >= 0 else {
            throw NateError.message("文件读取预算无效。")
        }
        guard permit() else {
            throw CancellationError()
        }
        let resolved =
            resolvingLinks ? url.resolvingSymlinksInPath().standardizedFileURL : url.standardizedFileURL
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw posix("无法读取原文件")
        }
        defer {
            Darwin.close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posix("无法读取原文件身份")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            throw NateError.message("只能将普通文件作为编辑和保存目标。")
        }
        guard metadata.st_size <= Int64(maximumBytes) else {
            throw NateError.message("文件超过 \(maximumBytes) 字节读取预算。")
        }
        var hasher = SHA256()
        var data = Data()
        if collectBytes {
            data.reserveCapacity(min(Int(min(metadata.st_size, 16_777_216)), maximumCaptureBytes))
        }
        var remaining = metadata.st_size
        var block = [UInt8](repeating: 0, count: 262_144)
        while remaining > 0 {
            guard permit() else {
                throw CancellationError()
            }
            let amount = try block.withUnsafeMutableBytes {
                bytes -> Int in
                let amount = Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    Int(min(remaining, Int64(bytes.count)))
                )
                if amount < 0 && errno == EINTR {
                    return -1
                }
                if amount == 0 {
                    throw NateError.message("读取期间原文件提前结束。")
                }
                guard amount > 0 else {
                    throw posix("原文件读取未完成")
                }
                let content = UnsafeRawBufferPointer(rebasing: bytes[..<amount])
                hasher.update(bufferPointer: content)
                try consume(content)
                if collectBytes, data.count < maximumCaptureBytes {
                    data.append(
                        contentsOf: content.prefix(min(content.count, maximumCaptureBytes - data.count))
                    )
                }
                return amount
            }
            if amount > 0 {
                remaining -= Int64(amount)
            }
        }
        guard permit() else {
            throw CancellationError()
        }
        var after = stat()
        var path = stat()
        // 描述符内容、路径身份及纳秒观察必须仍一致，不能把多个外部修订拼成一个保存基线。
        let descriptorResult = fstat(descriptor, &after)
        let pathResult = resolvingLinks ? stat(resolved.path, &path) : lstat(resolved.path, &path)
        guard descriptorResult == 0, pathResult == 0,
            sameObservation(metadata, after), sameObservation(after, path)
        else {
            throw NateError.message("获取磁盘证据期间文件发生变化。")
        }
        return FileReadEvidence(
            data: data,
            baseline: DiskBaseline(
                device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                inode: metadata.st_ino,
                digest: hasher.finalize().map {
                    String(format: "%02x", $0)
                }.joined(),
                resolvedPath: resolved.path
            ),
            totalByteCount: metadata.st_size
        )
    }
}
