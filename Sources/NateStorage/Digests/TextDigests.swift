import Foundation
import NateCore

public struct LineDigest: Sendable {
    public let line: Int
    public let byteCount: Int
    public let values: DigestValues
}

public enum TextDigests {
    /// 业务作用：文本摘要按固定原 UTF-8 字节计算，不转换原换行、不剥离正文 BOM 或 NUL。
    /// 参数说明:
    /// - text: 不可变正文或用户直接输入的文本树。
    /// - range: 明确来源范围，省略时读取全文。
    /// - deadline: 可选更早截止，不能延长内部五秒预算。
    /// - permit: 本次来源仍有效的取消资格。
    /// 返回：同一完整来源的四类摘要；非法范围、超过 64 MiB、超时或取消整体失败。
    public static func values(
        text: PieceTree,
        range: ByteRange? = nil,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DigestValues {
        let deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        try check(deadline: deadline, permit: permit)
        let range = range ?? ByteRange(0, text.byteCount)
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= text.byteCount else {
            throw NateError.invalidRange
        }
        guard range.count <= 64 * 1024 * 1024 else {
            throw NateError.message("文本摘要完整输入超过 64 MiB。")
        }
        let source = try text.slicing(range)
        var accumulator = DigestAccumulator(includeSHA256: true)
        try source.forEachChunk(maximumBytes: 65_536) {
            chunk in
            try check(deadline: deadline, permit: permit)
            chunk.bytes().withUnsafeBytes {
                accumulator.update($0)
            }
        }
        try check(deadline: deadline, permit: permit)
        return try accumulator.finalize()
    }

    /// 业务作用：逐行摘要排除每行实际 CR、LF 或 CRLF，连续空行和末尾换行产生的空行独立保留。
    /// 参数说明:
    /// - text: 固定原文本树。
    /// - range: 作为独立输入解释的明确范围，省略时为全文。
    /// - deadline: 整次逐行处理共享的更早截止时间。
    /// - permit: 整次处理仍有效的取消资格。
    /// 返回：从 1 开始的完整局部行序列及全部算法；超过十万行、64 MiB 或五秒时拒绝全部结果。
    public static func lines(
        text: PieceTree,
        range: ByteRange? = nil,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> [LineDigest] {
        let deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        try check(deadline: deadline, permit: permit)
        let range = range ?? ByteRange(0, text.byteCount)
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= text.byteCount else {
            throw NateError.invalidRange
        }
        guard range.count <= 64 * 1024 * 1024 else {
            throw NateError.message("逐行摘要输入超过 64 MiB。")
        }
        let source = try text.slicing(range)
        guard source.lineCount <= 100_000 else {
            throw NateError.message("逐行摘要超过十万行。")
        }
        var result: [LineDigest] = []
        result.reserveCapacity(source.lineCount)
        var emptyValues: DigestValues?
        for line in 0..<source.lineCount {
            // 已算出的摘要不授予后继行新的执行时间，缓存命中前仍须复验共同截止与取消资格。
            try check(deadline: deadline, permit: permit)
            let body = source.lineRange(line, includeEnding: false)
            let values: DigestValues
            // 同次操作内空行都对应零个原字节，只复用完整摘要，不复用行号、范围或执行资格。
            if body.isEmpty, let cached = emptyValues {
                values = cached
            }
            else {
                values = try Self.values(text: source, range: body, deadline: deadline, permit: permit)
                if body.isEmpty {
                    emptyValues = values
                }
            }
            result.append(
                LineDigest(
                    line: line + 1,
                    byteCount: body.count,
                    values: values
                )
            )
        }
        try check(deadline: deadline, permit: permit)
        return result
    }

    /// 业务作用：所有行和算法共用原取消资格与截止，不在每一行重新获得完整执行预算。
    /// 参数说明:
    /// - deadline: 整次原截止时间。
    /// - permit: 本次执行仍有效的资格。
    /// 返回：有效时继续，取消或超时整体失败。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("文本摘要超过五秒预算。")
        }
    }
}
