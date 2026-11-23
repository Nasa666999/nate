import Foundation
import NateCore
import NateStorage

struct ThemeSourceStamp: Sendable, Equatable {
    let size: Int64
    let modified: Date
    let device: UInt64
    let inode: UInt64
    let resolvedPath: String

    /// 业务作用：后台元数据只用于决定是否需要重读，不能替代完整配色原字节及摘要校验。
    /// 参数说明:
    /// - url: 已明确授权监视的本地来源。
    /// - permit: 当前来源监视仍有读取资格。
    /// 返回：有限普通文件的只读元数据，缺失、超量、改向或取消均拒绝。
    static func read(_ url: URL, permit: @Sendable () -> Bool) throws -> ThemeSourceStamp {
        guard permit() else {
            throw CancellationError()
        }
        try FileStorage.validateFileURL(url)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let fields = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard fields[.type] as? FileAttributeType == .typeRegular,
            let size = fields[.size] as? NSNumber, (0...Int64(8 * 1024 * 1024)).contains(size.int64Value),
            let modified = fields[.modificationDate] as? Date,
            let device = fields[.systemNumber] as? NSNumber,
            let inode = fields[.systemFileNumber] as? NSNumber, permit()
        else {
            throw NateError.message("主题来源不是 8 MiB 以内的有效普通文件，当前主题保留。")
        }
        return ThemeSourceStamp(
            size: size.int64Value,
            modified: modified,
            device: device.uint64Value,
            inode: inode.uint64Value,
            resolvedPath: resolved.path
        )
    }
}
