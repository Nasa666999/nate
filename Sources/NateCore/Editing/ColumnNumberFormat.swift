import Foundation

public enum ColumnNumberPadding: String, Sendable, Codable, CaseIterable {
    case none
    case zeros
    case spaces
}

public struct ColumnNumberFormat: Sendable, Codable, Equatable {
    public var start: Int64
    public var step: Int64
    public var radix: Int
    public var repetitions: Int
    public var padding: ColumnNumberPadding
    public var minimumWidth: Int
    public var uppercase: Bool

    /// 业务作用：记录列数字的完整生成意图，输入进制与输出进制使用同一明确选择。
    /// 参数说明:
    /// - start: 首个有符号整数。
    /// - step: 每个重复组之间的有符号增量。
    /// - radix: 二、八、十或十六进制。
    /// - repetitions: 每个整数连续使用的目标数量。
    /// - padding: 无填充、前导零或前导空格。
    /// - minimumWidth: 至少保留的总字符宽度，零表示按本次全部数字自动对齐。
    /// - uppercase: 十六进制字母是否大写。
    /// 返回：尚未执行生成或取得正文写入权的纯数据配置。
    public init(
        start: Int64 = 1,
        step: Int64 = 1,
        radix: Int = 10,
        repetitions: Int = 1,
        padding: ColumnNumberPadding = .none,
        minimumWidth: Int = 0,
        uppercase: Bool = true
    ) {
        self.start = start
        self.step = step
        self.radix = radix
        self.repetitions = repetitions
        self.padding = padding
        self.minimumWidth = minimumWidth
        self.uppercase = uppercase
    }

    /// 业务作用：按文档顺序准备完整数字序列，逐组相加避免中间乘法溢出误拒绝合法的跨零序列。
    /// 参数说明:
    /// - count: 本次真实编辑目标数量，最多十万项。
    /// - maximumBytes: 本轮可接收的 ASCII 输出总字节数，最多 256 MiB。
    /// - deadline: 整个列编辑计划共用的单调截止，为空时使用五秒。
    /// 返回：完整数字列表；参数、整数、输出容量、取消或时间超限时不返回部分序列。
    public func render(
        count: Int,
        maximumBytes: Int = 268_435_456,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> [String] {
        guard (0...100_000).contains(count), [2, 8, 10, 16].contains(radix),
            repetitions > 0, (0...4096).contains(minimumWidth),
            (0...268_435_456).contains(maximumBytes)
        else {
            throw NateError.message("列数字参数无效，数量最多十万项，填充宽度最多 4096。")
        }
        let ownDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        let deadline = min(deadline ?? ownDeadline, ownDeadline)
        try checkpoint(deadline)
        var raw: [String] = []
        raw.reserveCapacity(count)
        var number = start
        var widest = minimumWidth
        var rawBytes = 0
        for index in 0..<count {
            if index & 255 == 0 {
                try checkpoint(deadline)
            }
            if index > 0 && index % repetitions == 0 {
                let next = number.addingReportingOverflow(step)
                guard !next.overflow else {
                    throw NateError.message("列数字超出有符号 64 位整数范围，全部目标保持原状。")
                }
                number = next.partialValue
            }
            let text = String(number, radix: radix, uppercase: uppercase)
            guard text.utf8.count <= maximumBytes - rawBytes else {
                throw NateError.message("列数字超过本次完整输出容量，未生成部分序列。")
            }
            rawBytes += text.utf8.count
            widest = max(widest, text.utf8.count)
            raw.append(text)
        }
        guard padding != .none else {
            try checkpoint(deadline)
            return raw
        }
        // 全部数字长度已经明确，先检查最终对齐规模，再分配任何长填充字符串。
        let size = widest.multipliedReportingOverflow(by: count)
        guard !size.overflow, size.partialValue <= maximumBytes else {
            throw NateError.message("列数字填充后的总输出超过容量，全部目标保持原状。")
        }
        var result: [String] = []
        result.reserveCapacity(count)
        for (index, text) in raw.enumerated() {
            if index & 255 == 0 {
                try checkpoint(deadline)
            }
            let amount = widest - text.utf8.count
            if padding == .zeros && text.hasPrefix("-") {
                result.append("-" + String(repeating: "0", count: amount) + text.dropFirst())
            }
            else {
                result.append(String(repeating: padding == .zeros ? "0" : " ", count: amount) + text)
            }
        }
        try checkpoint(deadline)
        return result
    }

    /// 业务作用：数字准备与填充共享真实取消和时间预算，超时不继续占用编辑计划。
    /// 参数说明:
    /// - deadline: 本轮固定截止。
    /// 返回：仍可继续时返回，取消或五秒预算用尽时抛错。
    private func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("列数字准备超过五秒预算，全部目标保持原状。")
        }
    }
}
