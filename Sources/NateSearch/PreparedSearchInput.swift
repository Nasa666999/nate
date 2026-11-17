import Foundation
import NateCore

public struct PreparedSearchInput: Sendable {
    let snapshot: DocumentSnapshot
    let input: [UInt16]

    /// 业务作用：为一组只读结构规则共享正文投影，所有规则始终针对同一修订。
    /// 参数说明:
    /// - snapshot: 已提交不可变正文。
    /// 返回：可安全交给后台任务的投影，不改变文档。
    public init(snapshot: DocumentSnapshot) {
        self.snapshot = snapshot
        input = Array(snapshot.text.text().utf16)
    }

    /// 业务作用：在共享投影上执行独立规则，保持范围、捕获与搜索预算一致。
    /// 参数说明:
    /// - options: 表达式与搜索模式。
    /// - scope: 本次规则允许消费的范围。
    /// - firstOnly: 是否只获取首个命中，适用于逐层名称提取。
    /// - allowEmpty: 是否保留零长度结果；函数列表关闭此开关。
    /// 返回：固定修订中的结果；取消或规则超限时失败。
    public func find(
        options: SearchOptions,
        scope: ByteRange? = nil,
        firstOnly: Bool = false,
        allowEmpty: Bool = true
    ) throws -> SearchResult {
        try SearchEngine.find(
            in: snapshot,
            input: input,
            options: options,
            scope: scope,
            firstOnly: firstOnly,
            allowEmpty: allowEmpty
        )
    }
}
