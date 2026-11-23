import Foundation

struct TextLinkWork {
    private var remaining = 2_000_000
    private var untilCheck = 256
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool

    /// 业务作用：协议匹配、查询扫描和末尾裁剪共用一份工作量与来源预算。
    /// 参数说明:
    /// - deadline: 完整链接页计算的共同截止。
    /// - permit: 原正文及配置仍允许发布本次结果的资格。
    /// 返回：固定执行窗口的独立预算，不读取正文或访问协议目标。
    init(deadline: ContinuousClock.Instant, permit: @escaping @Sendable () -> Bool) {
        self.deadline = deadline
        self.permit = permit
    }

    /// 业务作用：所有候选的实际字符比较累计计费，重复尾部判断不能绕过共同容量。
    /// 参数说明:
    /// - amount: 本步骤将处理的非负字符工作量。
    /// 返回：额度充足且操作有效时消费额度，超量或取消时停止整份结果。
    mutating func consume(_ amount: Int = 1) throws {
        guard amount >= 0, amount <= remaining else {
            throw NateError.message("链接识别超过两百万项共同工作量，未发布部分链接。")
        }
        remaining -= amount
        untilCheck -= amount
        if untilCheck <= 0 {
            try check()
            untilCheck = 256
        }
    }

    /// 业务作用：链接分析与目标点击无关，失去正文或配置来源时必须停止旧结果发布。
    /// 参数说明: 无。
    /// 返回：未取消、来源有效且未超过截止时通过，否则不保留部分候选。
    func check() throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("链接识别已取消、来源失效或超过共同截止，未发布部分链接。")
        }
    }
}
