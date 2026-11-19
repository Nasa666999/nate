import Foundation
import NateCore

public struct HexEncodingOptions: Sendable, Codable, Equatable {
    public let uppercase: Bool
    public let separateBytes: Bool
    public let bytesPerLine: Int

    /// 业务作用：固定十六进制显示意图，执行前统一检查行宽与完整输出容量。
    /// 参数说明:
    /// - uppercase: 是否使用大写 A 至 F。
    /// - separateBytes: 是否在未换行的完整字节后插入一个空格。
    /// - bytesPerLine: 每行原字节数，零表示不自动换行。
    /// 返回：可编码的完整配置草稿；非法行宽在执行时拒绝。
    public init(uppercase: Bool = true, separateBytes: Bool = true, bytesPerLine: Int = 0) {
        self.uppercase = uppercase
        self.separateBytes = separateBytes
        self.bytesPerLine = bytesPerLine
    }
}

public enum HexCodec {
    public static let maximumBytes = 64 * 1024 * 1024

    /// 业务作用：把全部原字节转换为显式 HEX，不把非 ASCII 文字截断为一个字符或字节。
    /// 参数说明:
    /// - data: 固定原字节，包括 NUL。
    /// - options: 字母大小写、字节间隔和每行字节数，行宽范围为零至 4096。
    /// - lineEnding: 自动分行使用的实际文档结束符。
    /// - deadline: 可选更早截止，不能放宽五秒预算。
    /// - permit: 原请求仍有效的取消资格。
    /// 返回：全部 ASCII HEX；容量、行宽、取消或超时错误不返回部分内容。
    public static func encode(
        _ data: Data,
        options: HexEncodingOptions = HexEncodingOptions(),
        lineEnding: LineEnding = .lf,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = HexBudget(
            deadline: deadline,
            permit: permit
        )
        try budget.check()
        guard data.count <= maximumBytes, (0...4096).contains(options.bytesPerLine) else {
            throw NateError.message("HEX 输入超过 64 MiB，或每行字节数不在 0 至 4096 范围内。")
        }
        let ending = Array(lineEnding.text.utf8)
        let breaks = options.bytesPerLine == 0 ? 0 : data.count / options.bytesPerLine
        let spaces = options.separateBytes ? data.count - breaks : 0
        let size = data.count * 2 + spaces + breaks * ending.count
        // 先检查完整展开容量，不能在输出中途用截断前缀替换用户原文。
        guard size <= maximumBytes else {
            throw NateError.message("HEX 完整输出超过 64 MiB，未生成部分结果。")
        }
        let alphabet = Array((options.uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var output: [UInt8] = []
        output.reserveCapacity(size)
        try data.withUnsafeBytes {
            (bytes: UnsafeRawBufferPointer) in
            for index in bytes.indices {
                if index.isMultiple(of: 4096) {
                    try budget.check()
                }
                let byte = bytes[index]
                output.append(alphabet[Int(byte >> 4)])
                output.append(alphabet[Int(byte & 15)])
                if options.bytesPerLine > 0 && (index + 1).isMultiple(of: options.bytesPerLine) {
                    output.append(contentsOf: ending)
                }
                else if options.separateBytes {
                    output.append(32)
                }
            }
        }
        try budget.check()
        return Data(output)
    }

    /// 业务作用：完整 HEX 字节对还原为原字节，空白只能出现在完整字节之间，不能拼接残缺半字节。
    /// 参数说明:
    /// - data: 仅包含 ASCII HEX、空格、Tab、CR 和 LF 的固定输入。
    /// - deadline: 可选更早截止，不能放宽五秒预算。
    /// - permit: 原请求仍有效的取消资格。
    /// 返回：完整原字节，不假设为 UTF-8；非法、残缺、取消或超时整体失败。
    public static func decode(
        _ data: Data,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = HexBudget(
            deadline: deadline,
            permit: permit
        )
        try budget.check()
        guard data.count <= maximumBytes else {
            throw NateError.message("HEX 输入超过 64 MiB。")
        }
        var output: [UInt8] = []
        output.reserveCapacity(data.count / 2)
        var high: UInt8?
        try data.withUnsafeBytes {
            (bytes: UnsafeRawBufferPointer) in
            for index in bytes.indices {
                if index.isMultiple(of: 4096) {
                    try budget.check()
                }
                let byte = bytes[index]
                if byte == 32 || byte == 9 || byte == 13 || byte == 10 {
                    guard high == nil else {
                        throw NateError.message("HEX 空白不能分隔同一字节的两个数字。")
                    }
                    continue
                }
                let digit: UInt8
                switch byte {
                case 48...57: digit = byte - 48
                case 65...70: digit = byte - 65 + 10
                case 97...102: digit = byte - 97 + 10
                default: throw NateError.message("HEX 包含非法数字、前缀或非 ASCII 空白。")
                }
                if let first = high {
                    output.append(first << 4 | digit)
                    high = nil
                }
                else {
                    high = digit
                }
            }
        }
        guard high == nil else {
            throw NateError.message("HEX 末尾缺少完整字节的第二个数字。")
        }
        try budget.check()
        return Data(output)
    }
}

private struct HexBudget: Sendable {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool

    /// 业务作用：HEX 全部扫描和展开共用同一取消与截止，不在换行或字节对之间刷新预算。
    /// 参数说明:
    /// - deadline: 调用方更早的截止时间。
    /// - permit: 原动作的取消资格。
    /// 返回：最多五秒的完整处理预算。
    init(deadline: ContinuousClock.Instant?, permit: @escaping @Sendable () -> Bool) {
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        self.permit = permit
    }

    /// 业务作用：有界扫描步长检查原资格，取消或超时后不再交付任何前缀。
    /// 参数说明: 无。
    /// 返回：仍有效时继续，否则取消或明确失败。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("HEX 转换超过五秒预算，未发布部分结果。")
        }
    }
}
