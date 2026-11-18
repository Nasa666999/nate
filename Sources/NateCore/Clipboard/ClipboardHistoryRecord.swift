import Foundation

public struct ClipboardHistoryRecord: Sendable, Equatable {
    public let id: UUID
    public let capturedAt: Date
    public let payload: ClipboardPayload
    public let text: String
    public let retainedBytes: Int
    let encodedPayload: Data

    /// 业务作用：历史保留完整文字和形态并计入片段索引容量，不能用大量空片段绕过单条预算。
    /// 参数说明:
    /// - payload: 用户主动动作实际使用的完整载荷。
    /// - id: 记录的稳定身份，跨恢复和列表重排保持。
    /// - capturedAt: 本次主动动作的明确时刻，不从系统剪贴板推断来源应用。
    /// - deadline: 所属历史准备或恢复动作的共同截止。
    /// - permit: 当前仍有读取和构建资格。
    /// 返回：估计保留容量不超过 1 MiB 的完整记录；非法时刻、容量或取消时失败。
    public init(
        _ payload: ClipboardPayload,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        let metadata =
            payload.fragments.count * (MemoryLayout<ClipboardFragment>.stride + MemoryLayout<Int>.stride)
            + 256
        guard payload.plainByteCount <= 1_048_576 - metadata,
            capturedAt.timeIntervalSince1970.isFinite,
            (-62_135_596_800...253_402_300_799).contains(capturedAt.timeIntervalSince1970)
        else {
            throw NateError.message("该剪贴板内容、片段索引或时刻超过单条历史范围。")
        }
        let data = try payload.encoded(deadline: budget.deadline, permit: permit)
        let footprint = metadata + data.count + payload.plainByteCount
        guard footprint <= 1_048_576 else {
            throw NateError.message("该剪贴板完整内容与形态超过 1 MiB 历史容量。")
        }
        self.id = id
        self.capturedAt = capturedAt
        self.payload = payload
        text = try payload.plainText(deadline: budget.deadline, permit: permit)
        retainedBytes = footprint
        encodedPayload = data
    }
}

public enum ClipboardHistoryLimits {
    public static let records = 20
    public static let retainedBytes = 8_388_608
    public static let archiveBytes = 8_388_608

    /// 业务作用：用户明确产生新内容时，精确相同载荷移到最近位置并完整淘汰超量旧记录。
    /// 参数说明:
    /// - record: 本次实际主动动作的完整记录。
    /// - existing: 当前按最近顺序保存的记录。
    /// 返回：最多二十条、估计保留容量不超过 8 MiB 的完整列表，不截断任何一条正文。
    public static func inserting(_ record: ClipboardHistoryRecord, into existing: [ClipboardHistoryRecord])
        -> [ClipboardHistoryRecord]
    {
        var result = [record]
        var bytes = record.retainedBytes
        for value in existing.prefix(records) where value.id != record.id && value.payload != record.payload {
            guard result.count < records, value.retainedBytes <= retainedBytes - bytes else {
                break
            }
            result.append(value)
            bytes += value.retainedBytes
        }
        return result
    }
}
