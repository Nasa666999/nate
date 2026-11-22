import CryptoKit
import Foundation

struct UserConfigurationBudget {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let permit: @Sendable () -> Bool

    /// 业务作用：整份用户配置的读取、摘要与编码共用取消和时间边界。
    /// 参数说明: 无。
    /// 返回：当前资格有效且未超过五秒时继续，否则不交付部分配置。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("用户配置处理超过五秒，未采用部分结果。")
        }
    }
}

struct UserConfigurationWriter {
    var data = Data()
    let budget: UserConfigurationBudget

    /// 业务作用：完整字段追加前为整份摘要保留容量，超限不会返回截断归档。
    /// 参数说明:
    /// - bytes: 当前字段已经确认的完整原字节。
    /// 返回：全部追加或整体失败，始终保留末尾 32 字节摘要空间。
    mutating func append(_ bytes: Data) throws {
        try budget.check()
        guard bytes.count <= UserConfigurationArchive.maximumBytes - 32 - data.count else {
            throw NateError.message("用户配置归档超过 4 MiB。")
        }
        data.append(bytes)
    }

    /// 业务作用：协议固定字段按小端保存，不依赖当前主机内存对齐或整数表示顺序。
    /// 参数说明:
    /// - value: 已经过所属语义容量检查的无符号字段。
    /// 返回：追加完整固定宽度字段，取消或容量不足整体失败。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) throws {
        var little = value.littleEndian
        try withUnsafeBytes(of: &little) {
            try append(Data($0))
        }
    }
}

struct UserConfigurationReader {
    let data: Data
    let budget: UserConfigurationBudget
    var cursor = 0

    /// 业务作用：声明长度只能读取当前受限归档内的真实字节，切片 Data 的非零起点不改变协议坐标。
    /// 参数说明:
    /// - count: 已经过字段上限检查的完整字节数量。
    /// 返回：完整字段；截断、负数、取消或超时整体失败。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= data.count - cursor else {
            throw NateError.message("用户配置字段截断或长度无效。")
        }
        let start = data.startIndex + cursor
        cursor += count
        return Data(data[start..<(start + count)])
    }

    /// 业务作用：固定整数逐字节恢复，损坏长度不能触发未对齐读取或越界访问。
    /// 参数说明:
    /// - type: 当前协议字段的固定无符号宽度。
    /// 返回：完整小端值，字段不足时整体失败。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let field = try bytes(T.bitWidth / 8)
        var result: T = 0
        for (offset, byte) in field.enumerated() {
            result |= T(byte) << (offset * 8)
        }
        return result
    }

    /// 业务作用：字段按 UTF-8 原字节恢复，开头的 BOM 是正文标量而不是可丢弃的编码声明。
    /// 参数说明:
    /// - count: 已经过字段容量检查的完整原字节数。
    /// 返回：逐字节回编码一致的完整字符串；非法 UTF-8 整体拒绝，不替换或删除字符。
    mutating func text(_ count: Int) throws -> String {
        let raw = try bytes(count)
        guard let value = UTF8Text.decode(raw) else {
            throw NateError.invalidText
        }
        return value
    }
}

enum UserConfigurationDigest {
    /// 业务作用：整份配置摘要以固定小块处理，取消或截止不会等待整个归档散列后才被发现。
    /// 参数说明:
    /// - data: 已经过完整归档容量检查的原始正文。
    /// - budget: 本次编解码的共同资格与截止。
    /// 返回：完整 SHA-256 摘要，任何块失去资格均不交付摘要或部分配置。
    static func compute(_ data: Data, budget: UserConfigurationBudget) throws -> Data {
        var digest = SHA256()
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            try budget.check()
            let start = data.startIndex + offset
            let end = start + min(65_536, data.count - offset)
            digest.update(data: data[start..<end])
        }
        try budget.check()
        return Data(digest.finalize())
    }
}
