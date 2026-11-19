import Foundation
import NateCore

public struct FileDigestSnapshot: Sendable {
    public let requestedPath: String
    public let baseline: DiskBaseline
    public let byteCount: Int64
    public let values: DigestValues
}

extension FileStorage {
    /// 业务作用：摘要直接覆盖稳定磁盘文件的全部原字节，不使用解码正文或未保存缓冲区替代。
    /// 参数说明:
    /// - url: 用户明确选择的原文件 URL。
    /// - maximumBytes: 文件字节预算，默认允许平台完整文件大小。
    /// - progress: 工作线程交付的累计读取字节数，仅表示进度，不授予结果发布权。
    /// - permit: 本次读取仍有效的取消资格。
    /// 返回：同一描述符、完整身份及时间复验后的四类摘要与实际路径；变化或取消不提供部分结果。
    public static func digests(
        _ url: URL,
        maximumBytes: Int = Int.max,
        progress: @Sendable (Int64) -> Void = {
            _ in
        },
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> FileDigestSnapshot {
        try Task.checkCancellation()
        var accumulator = DigestAccumulator(includeSHA256: false)
        var consumed: Int64 = 0, reported: Int64 = 0
        let evidence = try readEvidence(
            url,
            collectBytes: false,
            maximumBytes: maximumBytes,
            consume: {
                bytes in
                try Task.checkCancellation()
                guard permit() else {
                    throw CancellationError()
                }
                accumulator.update(bytes)
                consumed += Int64(bytes.count)
                if consumed - reported >= 1_048_576 {
                    reported = consumed
                    progress(consumed)
                }
            },
            permit: permit
        )
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard consumed == evidence.totalByteCount else {
            throw NateError.message("文件摘要没有覆盖完整读取长度。")
        }
        // 完整身份和时间证据先于摘要发布，进度已到末尾也不能代替原路径与描述符复验。
        let values = try accumulator.finalize(fileSHA256: evidence.baseline.digest)
        progress(consumed)
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        return FileDigestSnapshot(
            requestedPath: url.path,
            baseline: evidence.baseline,
            byteCount: evidence.totalByteCount,
            values: values
        )
    }
}
