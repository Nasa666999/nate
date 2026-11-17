import Foundation
import NateCore

public struct PreparedSearchInput: Sendable {
    let snapshot: DocumentSnapshot

    /// 业务作用：为一组只读结构规则共享不可变正文证据，所有规则始终针对同一修订。
    /// 参数说明:
    /// - snapshot: 已提交不可变正文。
    /// 返回：可安全交给后台任务的廉价快照，不读取或复制整篇正文。
    public init(snapshot: DocumentSnapshot) {
        self.snapshot = snapshot
    }

    /// 业务作用：在共享快照上为独立结构规则建立有界读取缓存，消费范围受限，断言保留完整正文上下文。
    /// 参数说明:
    /// - options: 表达式与搜索模式。
    /// - scope: 本次规则允许消费的范围，不将结构范围截成新的全文。
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
            input: SearchInput(snapshot.text),
            options: options,
            scope: scope,
            firstOnly: firstOnly,
            allowEmpty: allowEmpty,
            limitContextToScope: false
        )
    }
}
