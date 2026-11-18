import Foundation

public struct SearchResultHitSelection: Sendable {
    public let batch: UUID
    public let file: UUID
    public let hits: [UUID]

    /// 业务作用：结果操作只传递用户当前选择的稳定身份，由拥有者复验原始来源而非信任显示文字。
    /// 参数说明:
    /// - batch: 当前保留的搜索批次。
    /// - file: 该批次中的文件分组。
    /// - hits: 当前选择或可见范围内的实际命中身份。
    /// 返回：不含正文与文件访问能力的操作请求。
    public init(batch: UUID, file: UUID, hits: [UUID]) {
        self.batch = batch
        self.file = file
        self.hits = hits
    }
}

extension SearchResultsPanel {
    /// 业务作用：命中操作沿当前筛选和分组选择收集原始身份，折叠与按行合并不丢弃实际匹配。
    /// 参数说明: 无。
    /// 返回：所选节点及其可见后代；没有选择时使用当前完整可见集合，说明与不可定位项不伪造命中。
    public func selectedResultHits() -> [SearchResultHitSelection] {
        let selected = selectedKeys()
        var result: [SearchResultHitSelection] = []
        for batch in filtered {
            let wholeBatch = selected.isEmpty || selected.contains(SearchResultTreeKey(batch: batch.batch.id))
            for file in batch.files {
                let wholeFile =
                    wholeBatch || selected.contains(SearchResultTreeKey(batch: batch.batch.id, file: file.id))
                let hits = file.rows.filter {
                    wholeFile
                        || selected.contains(
                            SearchResultTreeKey(batch: batch.batch.id, file: file.id, hit: $0.id)
                        )
                }.map(\.id)
                if !hits.isEmpty {
                    result.append(SearchResultHitSelection(batch: batch.batch.id, file: file.id, hits: hits))
                }
            }
        }
        return result
    }

    /// 业务作用：用户明确请求时才读取源行，完整准备前不清空或写入系统剪贴板。
    /// 参数说明: 无。
    /// 返回：当前合法命中交给来源拥有者，未确认筛选或没有命中时保留剪贴板。
    @objc func copySourceLines() {
        guard filterTask == nil, !filter.isEditingInput else {
            return
        }
        let selection = selectedResultHits()
        guard !selection.isEmpty else {
            feedback.stringValue = "当前没有可复制的命中行。"
            return
        }
        feedback.stringValue = "正在复验完整源行，完成后更新剪贴板。"
        onCopyLines?(selection)
    }

    /// 业务作用：来源操作的进度和失败保留在结果区域，不覆盖正文或查找表达式。
    /// 参数说明:
    /// - message: 属于当前有效操作的完整反馈。
    /// 返回：反馈更新，不移动焦点或改变结果选择。
    public func showOperationFeedback(_ message: String) {
        feedback.stringValue = message
    }
}
