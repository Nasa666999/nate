import CryptoKit
import Foundation

public enum ClipboardHistoryArchive {
    /// 业务作用：完整历史以显式格式和整份摘要归档，持久化不改变载荷的字节、顺序或形态。
    /// 参数说明:
    /// - records: 当前最近顺序的完整记录，最多二十条且合计不超过 8 MiB。
    /// - deadline: 所属持久化动作共同截止。
    /// - permit: 本次准备仍有执行资格。
    /// 返回：最多 8 MiB 的完整二进制归档；容量、身份、取消或超时失败不输出部分内容。
    public static func encode(
        _ records: [ClipboardHistoryRecord],
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard records.count <= ClipboardHistoryLimits.records,
            Set(records.map(\.id)).count == records.count,
            records.reduce(
                0,
                {
                    $0 + $1.retainedBytes
                }
            ) <= ClipboardHistoryLimits.retainedBytes
        else {
            throw NateError.message("剪贴板历史的身份、数量或总容量无效。")
        }
        var writer = ClipboardBinaryWriter(budget: budget)
        try writer.append(Data("NATEHIST".utf8))
        writer.unsigned(UInt16(1))
        writer.unsigned(UInt16(records.count))
        for record in records {
            try budget.check()
            try writer.append(Data(record.id.uuidString.utf8))
            // Date 原始参考秒直接往返，转换到其它纪元再转回会损失当前时刻的最低有效位。
            writer.unsigned(record.capturedAt.timeIntervalSinceReferenceDate.bitPattern)
            writer.unsigned(UInt32(record.encodedPayload.count))
            try writer.append(record.encodedPayload)
        }
        guard writer.data.count <= ClipboardHistoryLimits.archiveBytes - 32 else {
            throw NateError.message("剪贴板历史归档超过 8 MiB。")
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: writer.data))
        try budget.check()
        try writer.append(digest)
        return writer.data
    }

    /// 业务作用：历史恢复先检查总容量和完整摘要，再验证每份载荷，不把损坏或未知归档变成空历史。
    /// 参数说明:
    /// - data: 从同一次受限读取取得的完整原始文件，最多 8 MiB。
    /// - deadline: 所属恢复动作共同截止。
    /// - permit: 当前仍具有恢复执行资格。
    /// 返回：全部合法记录的原顺序；未知格式、重复身份、截断、超量或摘要不一致时整体失败。
    public static func decode(
        _ data: Data,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> [ClipboardHistoryRecord] {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard (44...ClipboardHistoryLimits.archiveBytes).contains(data.count) else {
            throw NateError.message("剪贴板历史归档长度无效或超过 8 MiB。")
        }
        let body = Data(data.dropLast(32))
        let digest = Data(SHA256.hash(data: body))
        try budget.check()
        guard digest.elementsEqual(data.suffix(32)) else {
            throw NateError.message("剪贴板历史归档摘要不一致，原文件保留。")
        }
        var reader = ClipboardBinaryReader(data: body, budget: budget)
        guard try reader.bytes(8) == Data("NATEHIST".utf8), try reader.unsigned(UInt16.self) == 1 else {
            throw NateError.message("剪贴板历史格式未知，原文件保留。")
        }
        let count = Int(try reader.unsigned(UInt16.self))
        guard count <= ClipboardHistoryLimits.records else {
            throw NateError.message("剪贴板历史超过二十条。")
        }
        var result: [ClipboardHistoryRecord] = []
        var identities: Set<UUID> = []
        var bytes = 0
        for _ in 0..<count {
            try budget.check()
            let identity = try reader.bytes(36)
            guard let value = UTF8Text.decode(identity), let id = UUID(uuidString: value),
                id.uuidString.utf8.elementsEqual(identity), identities.insert(id).inserted
            else {
                throw NateError.message("剪贴板历史记录身份无效或重复。")
            }
            let timestamp = Double(bitPattern: try reader.unsigned(UInt64.self))
            guard timestamp.isFinite, (-63_113_904_000...252_423_993_599).contains(timestamp) else {
                throw NateError.message("剪贴板历史记录时刻无效。")
            }
            let size = Int(try reader.unsigned(UInt32.self))
            guard size <= 1_048_576 else {
                throw NateError.message("剪贴板历史单条表示超过 1 MiB。")
            }
            let payload = try ClipboardPayload.decode(
                reader.bytes(size),
                deadline: budget.deadline,
                permit: permit
            )
            let record = try ClipboardHistoryRecord(
                payload,
                id: id,
                capturedAt: Date(timeIntervalSinceReferenceDate: timestamp),
                deadline: budget.deadline,
                permit: permit
            )
            guard record.retainedBytes <= ClipboardHistoryLimits.retainedBytes - bytes else {
                throw NateError.message("剪贴板历史内容与索引超过 8 MiB。")
            }
            result.append(record)
            bytes += record.retainedBytes
        }
        guard reader.cursor == body.count else {
            throw NateError.message("剪贴板历史归档含未知尾部，原文件保留。")
        }
        try budget.check()
        return result
    }
}
