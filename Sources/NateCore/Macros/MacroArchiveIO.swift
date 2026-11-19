import Foundation

public enum MacroArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat

    public var errorDescription: String? {
        "宏归档包含不受支持的格式或字段，原配置保留。"
    }
}

struct MacroArchiveBudget: Sendable {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let permit: @Sendable () -> Bool

    /// 业务作用：宏的编码、解析与动作校验共用截止和执行权，取消不能留下可使用的部分配置。
    /// 参数说明: 无。
    /// 返回：仍在五秒预算且资格有效时继续，否则整份失败。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("宏归档处理超过五秒，原配置保留。")
        }
    }
}

struct MacroArchiveWriter {
    var data = Data()
    let budget: MacroArchiveBudget
    let maximumBytes: Int

    /// 业务作用：单个宏与宏库共用固定字段编码，各自保留明确的完整归档容量。
    /// 参数说明:
    /// - budget: 所属完整归档的共同执行预算。
    /// - maximumBytes: 所属协议固定的归档字节上限，不接受用户输入。
    /// 返回：尚未追加字段的有界编码器。
    init(budget: MacroArchiveBudget, maximumBytes: Int = MacroArchive.maximumBytes) {
        self.budget = budget
        self.maximumBytes = maximumBytes
    }

    /// 业务作用：宏协议的固定字段使用小端布局，归档不依赖宿主内存表示。
    /// 参数说明:
    /// - value: 已通过所属字段边界检查的无符号值。
    /// 返回：完整追加协议字段。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// 业务作用：每份动作数据先通过剩余容量门禁，不能先建立超大中间归档才拒绝保存。
    /// 参数说明:
    /// - bytes: 一个完整字段的原始内容。
    /// 返回：归档仍在所属协议容量内；取消、截止或超量时不提供部分内容。
    mutating func append(_ bytes: Data) throws {
        try budget.check()
        guard bytes.count <= maximumBytes - data.count else {
            throw NateError.message("宏归档超过所属存储容量，原文件保留。")
        }
        data.append(bytes)
    }
}

struct MacroArchiveReader {
    let data: Data
    let budget: MacroArchiveBudget
    var cursor = 0

    /// 业务作用：完整读取固定协议字段，截断输入不触发越界或未对齐访问。
    /// 参数说明:
    /// - type: 当前无符号字段的固定宽度。
    /// 返回：原小端值；字节不足时拒绝整份归档。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let count = T.bitWidth / 8
        guard count <= data.count - cursor else {
            throw NateError.message("宏归档在字段中截断。")
        }
        var value: T = 0
        for offset in 0..<count {
            value |= T(data[data.startIndex + cursor + offset]) << (offset * 8)
        }
        cursor += count
        return value
    }

    /// 业务作用：变长内容只从同一次有界归档读取，声明长度不授予额外分配权限。
    /// 参数说明:
    /// - count: 当前字段的完整字节数。
    /// 返回：完整原字节；截断、取消或超时不返回部分字段。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= data.count - cursor else {
            throw NateError.message("宏归档的字段长度无效。")
        }
        let start = data.startIndex + cursor
        cursor += count
        return Data(data[start..<(start + count)])
    }
}
