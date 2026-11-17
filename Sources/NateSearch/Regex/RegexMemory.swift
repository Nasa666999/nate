import Foundation
import NateCore

extension CancellableMatcher {
    /// 业务作用：所有断言与原子子调用共用保留预算，嵌套区域不能各自重复取得完整容量。
    /// 参数说明:
    /// - paths: 即将额外保留的执行路径数量。
    /// - instructions: 包含路径外层续接在内的额外待执行节点数。
    /// 返回：容量完整可得时登记占用；超限前拒绝分配，不发布部分搜索结果。
    mutating func reserve(paths: Int, instructions: Int) throws {
        guard paths >= 0, instructions >= 0, paths <= 100_000 - retainedPaths,
            instructions <= 1_000_000 - retainedInstructions
        else {
            throw NateError.message("正则回溯路径或待执行节点超过共享内存预算。")
        }
        retainedPaths += paths
        retainedInstructions += instructions
    }

    /// 业务作用：路径完成、失败或取消后释放其真实保留状态，不把局部返回当成整次计算结束。
    /// 参数说明:
    /// - path: 不再用于当前搜索的路径及剩余续接。
    /// 返回：共享路径与节点配额可供仍在执行的区域使用。
    mutating func release(_ path: RegexPath) {
        retainedPaths -= 1
        retainedInstructions -= path.pending.count
    }

    /// 业务作用：把下一执行单元登记为当前路径的续接，构建长序列期间仍响应真实取消。
    /// 参数说明:
    /// - instruction: 完成当前单元后需要继续的动作。
    /// - path: 已登记占用的当前路径。
    /// 返回：预算允许时加入续接；失败时不增加待执行引用。
    mutating func push(_ instruction: RegexInstruction, onto path: inout RegexPath) throws {
        try checkpoint()
        try reserve(paths: 0, instructions: 1)
        path.pending.append(instruction)
    }

    /// 业务作用：在分配回退副本前登记其全部续接成本，长尾序列不会因大量分支绕过容量限制。
    /// 参数说明:
    /// - instructions: 本候选特有的续接，按栈压入顺序提供。
    /// - path: 候选需要继承的正文位置、捕获及外层续接。
    /// - choices: 当前区域尚未尝试的路径。
    /// 返回：完整登记的候选进入回溯栈；取消或容量不足时保持原路径可完整释放。
    mutating func fork(
        _ instructions: [RegexInstruction],
        from path: RegexPath,
        into choices: inout [RegexPath]
    ) throws {
        try checkpoint()
        try reserve(paths: 1, instructions: path.pending.count + instructions.count)
        var alternative = path
        alternative.pending.append(contentsOf: instructions)
        choices.append(alternative)
    }
}
