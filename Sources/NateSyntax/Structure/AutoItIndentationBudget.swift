import Foundation
import NateCore

struct AutoItIndentationBudget {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool
    private var steps = 0

    /// 业务作用：全部物理行、目标预览和结构栈复制共享同一次输入额度，续行不能重新取得计算资格。
    /// 参数说明:
    /// - deadline: 整批输入准备与最终提交共同使用的截止。
    /// - permit: 调用方继续准备该次输入的资格。
    /// 返回：尚未消费步骤的独立预算，实际执行仍须逐项登记。
    init(deadline: ContinuousClock.Instant, permit: @escaping @Sendable () -> Bool) {
        self.deadline = deadline
        self.permit = permit
    }

    /// 业务作用：在读取、复制或解释前登记真实规模，超限或撤权时停止整份结构动作准备。
    /// 参数说明:
    /// - count: 本次将要处理的字节或栈项数量。
    /// 返回：共享 33554432 步额度内继续；无效数量、超限、取消或截止时抛错。
    mutating func consume(_ count: Int = 1) throws {
        guard count >= 0, count <= 33_554_432 - steps else {
            throw NateError.message("AutoIt 语言缩进超过共同计算预算。")
        }
        let previous = steps
        steps += count
        if previous == 0 || count >= 256 || previous / 256 != steps / 256 {
            try check()
        }
    }

    /// 业务作用：传播、预览与最终动作发布前复验同一输入资格，失权不能变成继承缩进的成功结果。
    /// 参数说明: 无。
    /// 返回：仍具备完整资格时继续；取消或截止时抛错，不发布部分动作。
    func check() throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("AutoIt 语言缩进已取消或超过共同截止，正文与选择保持原状。")
        }
    }
}
