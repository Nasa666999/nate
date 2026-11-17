import Foundation
import NateCore

extension CancellableMatcher {
    /// 业务作用：将重复的扩展与退出路径按贪婪或懒惰优先级压入回溯栈，不预先枚举全部结果。
    /// 参数说明:
    /// - repetition: 当前次数、上下限、子表达式及扩展资格。
    /// - path: 当前优先执行的路径，完成后继续其外层表达式。
    /// - choices: 仅在当前路径失败时再尝试的候选。
    /// 返回：必需次数不足时安排子表达式，否则保留有序退出；空成功不无限重复。
    mutating func scheduleRepeat(_ repetition: RegexRepeat, path: inout RegexPath, choices: inout [RegexPath])
        throws
    {
        let expand = repetition.canExpand && repetition.count < repetition.maximum
        let accept = repetition.count >= repetition.minimum
        if accept {
            if expand {
                if repetition.greedy {
                    try fork([], from: path, into: &choices)
                    try push(.repeated(repetition, path.state.position), onto: &path)
                    try push(.node(repetition.child, repetition.depth + 1), onto: &path)
                }
                else {
                    try fork(
                        [
                            .repeated(repetition, path.state.position),
                            .node(repetition.child, repetition.depth + 1),
                        ],
                        from: path,
                        into: &choices
                    )
                }
            }
        }
        else {
            try push(.repeated(repetition, path.state.position), onto: &path)
            try push(.node(repetition.child, repetition.depth + 1), onto: &path)
        }
    }
}
