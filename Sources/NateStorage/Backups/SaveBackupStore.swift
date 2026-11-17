import Darwin
import Foundation
import NateCore

public struct SaveBackupStore: Sendable {
    public let directory: URL
    let cache = SaveBackupCache()
    static let metadataLimit = 8_388_608
    static let entryLimit = 65_536

    /// 业务作用：将保存前的原始字节固定在应用支持目录，不把备份写入用户原目录。
    /// 参数说明:
    /// - directory: 独立于工作区恢复内容的私有目录。
    /// 返回：可跨后台线程使用的存储入口；无效目录保留原证据并在访问时拒绝，事务由目录锁串行化。
    public init(directory: URL) {
        do {
            try FileStorage.validateFileURL(directory)
            self.directory = directory.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL
                .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        }
        catch {
            // 无效原路径不能先规范化成另一个合法名称，保留原 URL 供每次实际访问拒绝。
            self.directory = directory
        }
    }

    /// 业务作用：覆盖原文件之前先持久化经相同磁盘基线确认的原始字节和可浏览索引。
    /// 参数说明:
    /// - url: 当前保存的用户路径。
    /// - expected: 原文件必须仍匹配的内容与身份。
    /// - policy: 本次保存的保留策略。
    /// - authority: 可观察且随父保存撤销的派生发布权限。
    /// - now: 本次历史记录和期限计算的业务时刻。
    /// - permit: 保存请求仍有效的权限。
    /// 返回：备份和索引可靠持久化后继续；任何失败均不得授权原文件覆盖。
    public func preserve(
        _ url: URL,
        expected: DiskBaseline,
        policy: SaveBackupPolicy,
        authority: any FilePublicationScope,
        now: Date = Date(),
        permit: @Sendable () -> Bool
    ) throws {
        try policy.validate()
        guard policy.mode != .disabled else {
            return
        }
        try FileStorage.validateFileURL(url)
        try withDirectoryLock(create: true, permit: permit) {
            let current = try readIndex(permit: permit)
            try validateDependencies(current.index.entries, permit: permit)
            let evidence = try FileStorage.readEvidence(
                url,
                collectBytes: false,
                maximumBytes: Int(min(policy.maximumBytes, Int64(Int.max))),
                permit: permit
            )
            // 备份只能保护用户已经授权覆盖的同一份原文件，不能把迟到的外部内容混入当前保存。
            guard evidence.baseline == expected else {
                throw NateError.message("保存备份检测到外部变化，原文件覆盖已停止。")
            }
            let key = FileStorage.digest(Data(expected.resolvedPath.utf8))
            let existing = current.index.entries.first {
                $0.targetKey == key
            }
            let record: SavedFileBackup
            if let existing, existing.checksum == expected.digest {
                record = existing
            }
            else {
                record = SavedFileBackup(
                    targetKey: key,
                    originalPath: expected.resolvedPath,
                    checksum: expected.digest,
                    byteCount: evidence.totalByteCount,
                    created: now
                )
            }
            var entries = current.index.entries.filter {
                $0.id != record.id
            }
            entries.insert(record, at: 0)
            entries = try retained(entries, policy: policy, protected: record.id, now: now)
            try persistOriginal(
                url,
                expected: expected,
                byteCount: record.byteCount,
                authority: authority,
                permit: permit
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let bytes = try encoder.encode(SaveBackupIndex(entries: entries))
            guard bytes.count <= Self.metadataLimit else {
                throw NateError.message("保存备份索引超过 8 MB 预算，原文件保持原状。")
            }
            if current.bytes?.data != bytes {
                // 只有原字节已经同步后才发布历史入口，清理必须在这个入口可靠发布之后进行。
                try authority.withAuthority {
                    _ = try FileStorage.save(
                        bytes,
                        to: directory.appendingPathComponent("index.json"),
                        expected: current.bytes?.baseline,
                        permit: permit,
                        authority: $0
                    )
                }
            }
            try collectUnreferenced(entries, authority: authority, permit: permit)
        }
    }

    /// 业务作用：列出可选择的保存前内容，不授予任何原路径覆盖权限。
    /// 参数说明:
    /// - permit: 读取期间仍有效的请求权限。
    /// 返回：按最近保留时刻排序的历史；未知格式或损坏索引明确失败。
    public func list(
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> [SavedFileBackup] {
        try withDirectoryLock(create: false, permit: permit) {
            try readIndex(permit: permit).index.entries
        }
    }

    /// 业务作用：读取用户选择的历史原字节，用于建立独立文档而非覆盖当前原文件。
    /// 参数说明:
    /// - record: 从当前历史列表选择的内容身份。
    /// - maximumBytes: 调用方允许在内存中打开的字节上限。
    /// - permit: 请求权限。
    /// 返回：索引仍引用且长度和 SHA-256 一致的原始字节；失效引用或改向均拒绝。
    public func read(
        _ record: SavedFileBackup,
        maximumBytes: Int,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        try withDirectoryLock(create: false, permit: permit) {
            let index = try readIndex(permit: permit).index
            // 旧窗口中的条目可能已被保留策略清理，不能将无索引孤立文件冒认为仍有效的历史。
            guard index.entries.contains(record), record.byteCount <= Int64(maximumBytes) else {
                throw NateError.message("保存备份已不在当前保留范围，或超过打开预算。")
            }
            let bytes = try readPrivate(blobURL(record.checksum), maximumBytes: maximumBytes, permit: permit)
            guard bytes.baseline.digest == record.checksum, Int64(bytes.data.count) == record.byteCount else {
                throw NateError.message("保存备份的字节或摘要不符合索引，内容保持原状。")
            }
            return bytes.data
        }
    }

    /// 业务作用：在发布前计算全局期限、每路径数量和去重容量，不允许清理当前必须保护的旧正文。
    /// 参数说明:
    /// - entries: 包含本次旧原文件的候选历史。
    /// - policy: 已校验的策略。
    /// - protected: 本次覆盖前必须保留的内容身份。
    /// - now: 期限计算时刻。
    /// 返回：仍满足保护要求的有序记录；单份内容超出预算时停止原文件覆盖。
    func retained(
        _ entries: [SavedFileBackup],
        policy: SaveBackupPolicy,
        protected: String,
        now: Date
    ) throws -> [SavedFileBackup] {
        let cutoff = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
        let limit = policy.mode == .previous ? 1 : policy.versionsPerFile
        let ordered = entries.sorted {
            if $0.id == protected || $1.id == protected {
                return $0.id == protected && $1.id != protected
            }
            return $0.created == $1.created ? $0.id < $1.id : $0.created > $1.created
        }
        var counts: [String: Int] = [:]
        var contents: Set<String> = []
        var bytes: Int64 = 0
        var result: [SavedFileBackup] = []
        for entry in ordered {
            guard entry.id == protected || entry.created >= cutoff else {
                continue
            }
            guard counts[entry.targetKey, default: 0] < limit else {
                continue
            }
            let additional = contents.contains(entry.checksum) ? 0 : entry.byteCount
            guard additional <= policy.maximumBytes - bytes, result.count < Self.entryLimit else {
                if entry.id == protected {
                    throw NateError.message("覆盖前的原文件超过保存备份容量，原文件保持原状。")
                }
                continue
            }
            result.append(entry)
            counts[entry.targetKey, default: 0] += 1
            contents.insert(entry.checksum)
            bytes += additional
        }
        return result
    }
}
