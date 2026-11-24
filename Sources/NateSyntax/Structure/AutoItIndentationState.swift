import Foundation
import NateCore

struct AutoItIndentationState {
    private struct Frame {
        let kind: AutoItIndentationKind
        let prefix: String
        var finalBranch = false
    }
    private var frames: [Frame] = []
    private var logical: [UInt8] = []
    private var logicalPrefix: String?

    /// 业务作用：按连续物理行组成逻辑语句，只有完整结构语句才能改变后继代码的缩进来源。
    /// 参数说明:
    /// - code: 已遮蔽字面和注释的当前完整行或插入点之前的前缀。
    /// - prefix: 当前物理行原有的空格与 Tab 前缀。
    /// - budget: 全部行及光标共用的结构准备预算。
    /// 返回：该边界后新行的完整动作；不完整或普通语句继承原行，超限或撤权时抛错。
    mutating func consume(
        _ code: [UInt8],
        prefix: String,
        budget: inout AutoItIndentationBudget
    ) throws -> NewlineIndentationAction {
        try budget.consume(code.count)
        guard code.count <= 1_048_576 - logical.count else {
            throw NateError.message("AutoIt 语言缩进的完整续行语句超过 1 MiB。")
        }
        let origin = logicalPrefix ?? prefix
        // 预览和续接都可能触发既有逻辑行的写时复制，其真实长度必须在分配前计入同一额度。
        try budget.consume(logical.count)
        var joined = logical
        joined.append(contentsOf: code)
        var end = joined.count
        while end > 0 && [9, 10, 13, 32].contains(joined[end - 1]) {
            try budget.consume()
            end -= 1
        }
        if end >= 2, joined[end - 1] == 95,
            joined[end - 2] == 32 || joined[end - 2] == 9
        {
            joined[end - 1] = 32
            logical = joined
            logicalPrefix = origin
            return .inherit
        }
        let statement = try AutoItIndentationStatement.parse(joined, budget: &budget)
        logical = []
        logicalPrefix = nil
        return try apply(statement, prefix: origin, budget: &budget)
    }

    /// 业务作用：结构对齐只引用当前合法嵌套的同类开端，分支不能越过未闭合的内部块取得外层前缀。
    /// 参数说明:
    /// - statement: 完整逻辑语句确认的结构职责。
    /// - prefix: 逻辑语句首行的原空白。
    /// - budget: 当前输入的共同额度。
    /// 返回：明确同源的对齐动作；不匹配的闭合或重复最终分支不改变既有结构。
    private mutating func apply(
        _ statement: AutoItIndentationStatement,
        prefix: String,
        budget: inout AutoItIndentationBudget
    ) throws -> NewlineIndentationAction {
        switch statement {
        case .none:
            return .inherit
        case .open(let kind):
            // 目标预览会共享结构栈，登记写时复制的真实规模后才能派生新候选。
            try budget.consume(frames.count + 1)
            guard frames.count < 65_536 else {
                throw NateError.message("AutoIt 语言缩进超过 65536 个未闭合块。")
            }
            frames.append(Frame(kind: kind, prefix: prefix))
            return .align(prefix: prefix, levels: 1)
        case .close(let kind):
            // 结构证据不足时不能从更外层借用前缀，错误嵌套仍按用户当前缩进继续。
            guard let frame = frames.last, frame.kind == kind else {
                return .inherit
            }
            try budget.consume(frames.count)
            frames.removeLast()
            return .align(prefix: frame.prefix, levels: 0)
        case .alternate(let final):
            // 最终分支之后或不同嵌套内部的 Else 不具有外层条件块的对齐资格。
            guard let frame = frames.last, frame.kind == .conditional, !frame.finalBranch else {
                return .inherit
            }
            try budget.consume(frames.count)
            frames[frames.count - 1].finalBranch = final
            return .align(prefix: frame.prefix, levels: 1)
        case .branch(let final):
            // Case 只能引用直接所属的 Switch 或 Select，不能越过未结束的内部控制块。
            guard let frame = frames.last,
                frame.kind == .switchBlock || frame.kind == .selectBlock,
                !frame.finalBranch
            else {
                return .inherit
            }
            try budget.consume(frames.count)
            frames[frames.count - 1].finalBranch = final
            return .align(prefix: frame.prefix, levels: 2)
        }
    }
}
