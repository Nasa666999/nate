import Foundation

public struct PreparedTextHighlights: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    private let state: DocumentMarkState

    /// 业务作用：在后台为视图临时高亮构建完整范围索引，不进入正文持久标记、历史或恢复数据。
    /// 参数说明:
    /// - snapshot: 高亮所依据的固定正文。
    /// - ranges: 完整匹配范围，至多十万项，允许无正文的边界指示。
    /// - permit: 当前构建仍持有的取消权限。
    /// 返回：共用两秒构建预算的不可变索引；非法端点、取消或超限不返回部分高亮。
    public init(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        let plan = try PreparedDocumentMarks(
            snapshot: DocumentMarkSnapshot(
                document: snapshot,
                generation: UUID(),
                marks: DocumentMarkState()
            ),
            ranges: ranges,
            style: .search,
            append: false,
            permit: permit
        )
        documentID = snapshot.id
        revision = snapshot.revision
        state = plan.state
    }

    /// 业务作用：独立临时图层保留每个真实匹配，不借用用户颜色组的数量或生命周期。
    /// 参数说明: 无。
    /// 返回：已排序并去重的全部原始范围。
    public var ranges: [ByteRange] {
        state.ranges(for: .search)
    }

    /// 业务作用：视图只读取当前逻辑行相交的合并高亮，文档其他范围不增加逐行绘制扫描。
    /// 参数说明:
    /// - range: 当前可见逻辑行的正文范围。
    /// - limit: 整帧尚可绘制的范围数量。
    /// 返回：有界相交范围，超限明确失败且原始索引仍保留。
    public func displayRanges(intersecting range: ByteRange, limit: Int) throws -> [ByteRange] {
        try state.displayRanges(for: .search, intersecting: range, limit: limit)
    }
}
