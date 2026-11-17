import Foundation
import NateCore

extension SearchEngine {
    /// 业务作用：按批量查找的相同继续规则累计命中数量，不保留每项范围、捕获和上下文。
    /// 参数说明:
    /// - snapshot: 已提交的不可变正文。
    /// - options: 完整查询、大小写、全词与执行预算。
    /// - scope: 明确的授权字节范围；失效选区不得扩大为全文。
    /// - permit: 脱离 Swift Task 的队列中仍然有效的显式请求权限。
    /// 返回：完整命中数量，不受展示条目上限限制；表达式、扫描时间、执行步数、取消或整数容量失败时不返回部分数量。
    public static func count(
        in snapshot: DocumentSnapshot,
        options: SearchOptions,
        scope: ByteRange? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Int {
        try Task.checkCancellation()
        // 失权请求先于正文读取被拒绝，计数也不能继续占用原文档或建立派生缓存。
        guard permit() else {
            throw CancellationError()
        }
        try options.validateInput()
        var count = 0
        _ = try find(
            in: snapshot,
            input: SearchInput(snapshot.text),
            options: options,
            scope: scope,
            firstOnly: false,
            allowEmpty: true,
            permit: permit,
            onHit: {
                _ in
                guard count < Int.max else {
                    throw NateError.message("匹配数量超过整数容量，未返回部分计数。")
                }
                count += 1
            }
        )
        return count
    }
}
