import Foundation

public enum RunCommandArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat

    public var errorDescription: String? {
        "运行配置包含不受支持的格式或字段，原配置保留。"
    }
}

struct RunCommandArchiveBudget: Sendable {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let permit: @Sendable () -> Bool

    /// 业务作用：完整配置的编解码共用预算，取消不产生可使用的部分命令库。
    /// 参数说明: 无。
    /// 返回：仍在五秒预算且资格有效时继续，否则整份拒绝。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("运行配置处理超过五秒，原配置保留。")
        }
    }
}

struct RunCommandArchiveWriter {
    var data = Data()
    let budget: RunCommandArchiveBudget

    /// 业务作用：固定无符号字段先核对剩余容量，再写入小端协议表示。
    /// 参数说明:
    /// - value: 已通过所属字段边界检查的无符号值。
    /// 返回：完整追加字段；取消或容量不足拒绝整份归档。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) throws {
        var little = value.littleEndian
        try withUnsafeBytes(of: &little) {
            try append(Data($0))
        }
    }

    /// 业务作用：字段内容在分配到最终归档之前受完整存储容量约束。
    /// 参数说明:
    /// - bytes: 当前完整字段的原始字节。
    /// 返回：完整追加或整份失败，不返回截断配置。
    mutating func append(_ bytes: Data) throws {
        try budget.check()
        guard bytes.count <= RunCommandArchive.maximumBytes - data.count else {
            throw NateError.message("运行配置归档超过 8 MiB。")
        }
        data.append(bytes)
    }

    /// 业务作用：可执行路径、参数和目录均保存完整 UTF-8，不按 shell 语法解释。
    /// 参数说明:
    /// - value: 已通过模型门禁的单个完整模板。
    /// 返回：写入明确字节长度和原文。
    mutating func text(_ value: String) throws {
        try unsigned(UInt32(value.utf8.count))
        try append(Data(value.utf8))
    }
}

struct RunCommandArchiveReader {
    let data: Data
    let budget: RunCommandArchiveBudget
    var cursor = 0

    /// 业务作用：固定整数读取不依赖内存对齐，截断字段不能越界访问。
    /// 参数说明:
    /// - type: 协议字段的固定无符号宽度。
    /// 返回：完整小端值；截断、取消或超时拒绝整份。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let bytes = try bytes(T.bitWidth / 8)
        var value: T = 0
        for (offset, byte) in bytes.enumerated() {
            value |= T(byte) << (offset * 8)
        }
        return value
    }

    /// 业务作用：声明长度只取得当前有界归档内的字节，不授予额外读取或分配资格。
    /// 参数说明:
    /// - count: 当前字段完整字节数。
    /// 返回：原始完整字段，非法长度或截断明确失败。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= data.count - cursor else {
            throw NateError.message("运行配置在字段中截断或长度无效。")
        }
        let start = data.startIndex + cursor
        cursor += count
        return Data(data[start..<(start + count)])
    }

    /// 业务作用：路径与参数以严格 UTF-8 恢复，声明超量长度不能先建立中间字符串。
    /// 参数说明: 无。
    /// 返回：最多 1 MiB 的完整模板；非法 UTF-8、超量或截断拒绝。
    mutating func text() throws -> String {
        let size = Int(try unsigned(UInt32.self))
        guard size <= NamedRunCommand.maximumFieldBytes else {
            throw NateError.message("运行配置单字段超过 1 MiB。")
        }
        guard let value = UTF8Text.decode(try bytes(size)) else {
            throw NateError.invalidText
        }
        return value
    }
}
