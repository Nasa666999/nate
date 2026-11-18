import Foundation

struct RevisionPositionMap {
    let from: UInt64
    let to: UInt64
    let positions: PositionMap
}

extension DocumentBuffer {
    /// 业务作用：克隆视图使用同一完整修订链移动自己的稳定身份，不借当前活动视图覆盖其选择。
    /// 参数说明:
    /// - state: 该视图原先持有的完整选择与主项。
    /// - observedRevision: 该状态对应的原正文修订。
    /// 返回：完整链存在且最终范围合法时的独立状态；缺链、预算不足或无效范围时为空。
    public func mapSelectionState(_ state: SelectionState, from observedRevision: UInt64) -> SelectionState? {
        if observedRevision == revision {
            return try? state.validated(in: text, checkingCancellation: false)
        }
        guard observedRevision < revision,
            let index = positionJournal.firstIndex(where: {
                $0.from == observedRevision
            }), positionJournal.last?.to == revision
        else {
            return nil
        }
        let chain = positionJournal[index...].map(\.positions)
        let preserving = chain.allSatisfy {
            $0.changeCount == 0 || $0.permutation != nil
        }
        return try? state.mapped(
            through: chain,
            in: text,
            preservingRectangle: preserving,
            checkingCancellation: false
        )
    }

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

    /// 业务作用：正文与元数据准备完毕后登记视图位置转换，不持有旧正文。
    /// 参数说明:
    /// - positions: 当前修订到下一修订的完整映射。
    /// 返回：完整映射进入修订链，最多保留 256 个连续事务与一百万项索引，至少保留最后一个事务。
    func recordPositions(_ positions: PositionMap) {
        // 所有可失败的元数据映射已经完成，登记与修订发布之间不再开放新的等待点。
        positionJournal.append(RevisionPositionMap(from: revision, to: revision + 1, positions: positions))
        positionJournalChanges += positions.changeCount
        while positionJournal.count > 256 || (positionJournal.count > 1 && positionJournalChanges > 1_000_000)
        {
            positionJournalChanges -= positionJournal.removeFirst().positions.changeCount
        }
    }
}
