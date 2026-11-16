import Foundation

struct RevisionPositionMap {
    let from: UInt64
    let to: UInt64
    let positions: PositionMap
}

extension DocumentBuffer {
    /// 业务作用：克隆视图跨过多个事务时连续映射自己的光标，不只套用最后一次变化。
    /// 参数说明:
    /// - values: 该视图最后看到的选区。
    /// - observedRevision: 选区所属正文修订。
    /// 返回：完整修订链仍保留时返回映射；证据已超出预算时为空。
    public func mapSelections(_ values: [TextSelection], from observedRevision: UInt64) -> [TextSelection]? {
        if observedRevision == revision {
            return values
        }
        guard observedRevision < revision,
            let index = positionJournal.firstIndex(where: {
                $0.from == observedRevision
            }),
            positionJournal.last?.to == revision
        else {
            return nil
        }
        var result = values
        for transition in positionJournal[index...] {
            result = result.map {
                TextSelection(
                    anchor: transition.positions.map($0.anchor),
                    head: transition.positions.map($0.head),
                    virtualColumn: $0.virtualColumn
                )
            }
        }
        return result
    }

    /// 业务作用：正文发布前登记位置转换，保留记录只承担视图位置责任，不持有旧正文。
    /// 参数说明:
    /// - positions: 当前修订到下一修订的完整映射。
    /// 返回：最多保留 256 个连续事务与一百万项范围变化，至少保留最后一个事务。
    func recordPositions(_ positions: PositionMap) {
        positionJournal.append(RevisionPositionMap(from: revision, to: revision + 1, positions: positions))
        positionJournalChanges += positions.changeCount
        while positionJournal.count > 256 || (positionJournal.count > 1 && positionJournalChanges > 1_000_000)
        {
            positionJournalChanges -= positionJournal.removeFirst().positions.changeCount
        }
    }
}
