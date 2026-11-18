import Foundation

struct PreparedMarkRelocation: Sendable {
    let generation: UUID
    let state: DocumentMarkState
}

extension PreparedTransaction {
    /// 业务作用：整行重排同时准备正文、双向锚点与可选颜色，正文与物理换行均按真实原字节验证。
    /// 参数说明:
    /// - snapshot: 原文档身份与不可变正文。
    /// - text: 已按实际顺序构建的完整新正文。
    /// - permutation: 真实字节片段和行锚点的完整移动关系。
    /// - selectionsAfter: 明确结果选区，为空时按原行锚点移动当前选区。
    /// - marks: 可选的原颜色快照，后台准备可避免发布时重新计算大批颜色。
    /// - name: 用户可理解的撤销动作。
    /// - permit: 整个验证和颜色准备共用的执行资格。
    /// 返回：完整行事务；字节、范围、颜色或权限无效时不产生部分正文；相同字节的不同显式行顺序仍保留撤销。
    public init(
        permuting snapshot: DocumentSnapshot,
        to text: PieceTree,
        using permutation: TextPermutation,
        selectionsAfter: [TextSelection]? = nil,
        marks: DocumentMarkSnapshot? = nil,
        name: String,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard snapshot.text.byteCount == text.byteCount,
            permutation.scope.upper <= text.byteCount,
            snapshot.text.isBoundary(permutation.scope.lower),
            snapshot.text.isBoundary(permutation.scope.upper),
            text.isBoundary(permutation.scope.lower), text.isBoundary(permutation.scope.upper)
        else {
            throw NateError.invalidRange
        }
        for segment in permutation.forward {
            try Task.checkCancellation()
            guard permit() else {
                throw CancellationError()
            }
            guard segment.source.count == segment.destination.count,
                try snapshot.text.slicing(segment.source).byteEqual(
                    to: text.slicing(segment.destination),
                    permit: permit
                )
            else {
                throw NateError.message("重排片段与实际原字节不符，未发布正文或锚点。")
            }
        }
        for (index, point) in permutation.anchors.enumerated() {
            if index & 255 == 0 {
                try Task.checkCancellation()
                guard permit() else {
                    throw CancellationError()
                }
            }
            guard snapshot.text.isBoundary(point.source), text.isBoundary(point.destination) else {
                throw NateError.invalidRange
            }
        }
        let prefix = ByteRange(0, permutation.scope.lower)
        let suffix = ByteRange(permutation.scope.upper, text.byteCount)
        guard try snapshot.text.slicing(prefix).byteEqual(to: text.slicing(prefix), permit: permit),
            try snapshot.text.slicing(suffix).byteEqual(to: text.slicing(suffix), permit: permit)
        else {
            throw NateError.message("重排区间之外的正文已改变，未发布越界修改。")
        }
        if let selectionsAfter {
            guard
                selectionsAfter.allSatisfy({
                    text.isBoundary($0.anchor) && text.isBoundary($0.head)
                })
            else {
                throw NateError.invalidRange
            }
        }
        if let marks {
            guard marks.document.id == snapshot.id, marks.document.revision == snapshot.revision,
                try marks.document.text.byteEqual(to: snapshot.text, permit: permit)
            else {
                throw NateError.staleRevision
            }
            markUpdate = PreparedMarkRelocation(
                generation: marks.generation,
                state: try marks.marks.relocated(by: permutation, in: text, permit: permit)
            )
        }
        documentID = snapshot.id
        revision = snapshot.revision
        before = snapshot.text
        after = text
        edits = []
        changes =
            permutation.isIdentity
            ? [] : [PositionChange(range: permutation.scope, insertedByteCount: permutation.scope.count)]
        positions = PositionMap(permutation: permutation)
        reversePositions = PositionMap(permutation: permutation.inverse)
        selections = selectionsAfter
        format = nil
        self.name = name
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
    }
}
