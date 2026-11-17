import Foundation
import NateCore

struct ReplacementBudget {
    static let itemLimit = 64 * 1024 * 1024
    static let outputLimit = 256 * 1024 * 1024
    static let documentLimit = 1024 * 1024 * 1024
    static let formatLimit = 1024 * 1024
    let deadline: ContinuousClock.Instant
    var steps = 0
    var workBytes = 0

    /// 业务作用：整份替换计划共用计算预算，嵌套格式和多个命中不能分别取得新的完整额度。
    /// 参数说明:
    /// - deadline: 本份计划实际停止计算的时刻。
    /// 返回：未消耗的计划预算，不授予正文修改权限。
    init(deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))) {
        self.deadline = deadline
    }

    /// 业务作用：在格式扫描及原文读取边界执行真正的任务取消和截止检查。
    /// 参数说明:
    /// - force: 是否立即检查，而非等待周期边界。
    /// 返回：超出五百万步、实际取消或到达截止时停止整个计划。
    mutating func checkpoint(force: Bool = false) throws {
        steps += 1
        guard steps <= 5_000_000 else {
            throw NateError.message("替换格式计算超过 500 万步预算。")
        }
        if force || steps & 255 == 0 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("替换计划超过计算截止时间。")
            }
        }
    }

    /// 业务作用：在原文复制、片段处理及输出追加之前计入对应字节工作量。
    /// 参数说明:
    /// - bytes: 本次将要读取或生成的 UTF-8 字节数。
    /// 返回：累计读取、片段处理与输出追加不超过 512 MiB；超限在继续处理前失败。
    mutating func reserve(_ bytes: Int) throws {
        try checkpoint(force: true)
        guard bytes >= 0, bytes <= 512 * 1024 * 1024 - workBytes else {
            throw NateError.message("替换读取与中间展开超过 512 MiB 预算。")
        }
        workBytes += bytes
    }
}
