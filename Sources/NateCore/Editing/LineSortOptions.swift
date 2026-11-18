import Foundation

public enum LineSortKind: String, Sendable, Codable, CaseIterable {
    case lexicographic, ignoringCase, locale, integer, decimalComma, decimalDot, length, reverse, random
}

public struct LineSortOptions: Sendable, Equatable, Codable {
    public var kind: LineSortKind
    public var descending: Bool
    public var localeIdentifier: String

    /// 业务作用：明确排序键的解释和方向，区域规则使用用户可见的 macOS locale 身份。
    /// 参数说明:
    /// - kind: 字符、语言、数值、长度或直接行重排方式。
    /// - descending: 比较类排序是否降序，反转和随机不使用此参数。
    /// - localeIdentifier: 区域排序使用的明确语言地区身份。
    /// 返回：不依赖进程全局 locale 的完整排序配置。
    public init(
        kind: LineSortKind = .lexicographic,
        descending: Bool = false,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.kind = kind
        self.descending = descending
        self.localeIdentifier = localeIdentifier
    }
}

struct LineSortBudget: Sendable {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool

    /// 业务作用：取键、比较、正文构建和验证共享执行预算，旧任务不能在排序阶段继续耗用资源。
    /// 参数说明: 无。
    /// 返回：取消、失权或三十秒截止时整次失败，不返回部分行序。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("行排序超过三十秒预算，正文与原选区保留。")
        }
    }
}
