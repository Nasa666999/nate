import Foundation

public enum SelectionArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat

    public var errorDescription: String? {
        "完整选择归档格式不受支持，原记录保留。"
    }
}

struct SelectionArchiveWriter {
    var data = Data()
    let budget: SelectionPreparationBudget

    /// 业务作用：以固定小端字段保存完整选择，不依赖处理器对齐或对象内存布局。
    /// 参数说明:
    /// - value: 所属协议字段的已验证无符号值。
    /// 返回：完整追加固定宽度字段。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// 业务作用：恢复元数据的变长字段先通过容量门禁，再完整进入同一归档。
    /// 参数说明:
    /// - bytes: 一个字段的完整原始字节。
    /// 返回：追加成功；超量、取消或超时不提供部分归档。
    mutating func append(_ bytes: Data) throws {
        try budget.check()
        guard bytes.count <= SelectionStateArchive.maximumBytes - data.count else {
            throw NateError.message("完整选择归档超过 6 MiB，原状态保留。")
        }
        data.append(bytes)
    }

    /// 业务作用：保存正文坐标和列计数前拒绝截断，防止恢复到另一个实际位置。
    /// 参数说明:
    /// - value: 不超过单文档正文预算的字节坐标或列数。
    /// 返回：完整追加四字节无符号数，负值或超量时失败。
    mutating func coordinate(_ value: Int) throws {
        guard (0...1_073_741_824).contains(value) else {
            throw NateError.message("完整选择坐标超出 1 GiB 正文范围。")
        }
        unsigned(UInt32(value))
    }
}

struct SelectionArchiveReader {
    let data: Data
    let budget: SelectionPreparationBudget
    var cursor = 0

    /// 业务作用：恢复固定字段只接受完整原字节，截断不能触发越界或未对齐访问。
    /// 参数说明:
    /// - type: 当前协议字段的无符号整数宽度。
    /// 返回：原小端值；字节不足时拒绝整份归档。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let count = T.bitWidth / 8
        guard count <= data.count - cursor else {
            throw NateError.message("完整选择归档字段截断。")
        }
        var value: T = 0
        for offset in 0..<count {
            value |= T(data[data.startIndex + cursor + offset]) << (offset * 8)
        }
        cursor += count
        return value
    }

    /// 业务作用：声明长度必须落在同一有界归档中，不能按未验证长度分配恢复对象。
    /// 参数说明:
    /// - count: 当前变长字段的明确字节数。
    /// 返回：完整字段数据；取消、超时或截断时失败。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= data.count - cursor else {
            throw NateError.message("完整选择归档长度无效。")
        }
        let start = data.startIndex + cursor
        cursor += count
        return Data(data[start..<(start + count)])
    }

    /// 业务作用：恢复坐标遵循保存时相同的正文预算，不把过大字段转成有效范围。
    /// 参数说明: 无。
    /// 返回：一份合法坐标；超过 1 GiB 时拒绝归档。
    mutating func coordinate() throws -> Int {
        let value = Int(try unsigned(UInt32.self))
        guard value <= 1_073_741_824 else {
            throw NateError.message("完整选择坐标超出 1 GiB 正文范围。")
        }
        return value
    }
}
