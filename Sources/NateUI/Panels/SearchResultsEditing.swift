import AppKit

extension SearchResultsPanel {
    /// 业务作用：从持久设置同步历史策略，不把程序恢复视为用户再次勾选。
    /// 参数说明:
    /// - preferences: 当前完整结果偏好。
    /// 返回：控件与内存快照一致，既有批次不立即清除。
    public func setPreferences(_ preferences: SearchResultPreferences) {
        self.preferences = preferences
        clearPrevious.state = preferences.clearPrevious ? .on : .off
    }

    /// 业务作用：用户明确切换后续查询的结果保留方式，通知拥有者持久化而不触碰源文件。
    /// 参数说明: 无。
    /// 返回：新策略供下一次完整查询发布使用，当前历史仍保留。
    @objc func resultPreferencesChanged() {
        preferences.clearPrevious = clearPrevious.state == .on
        onPreferencesChange?(preferences)
    }

    /// 业务作用：删除命令依据稳定节点层级收回展示条目，不把所选命中扩大为整个批次。
    /// 参数说明: 无。
    /// 返回：完整选择作为单一请求交给拥有者，失效对象或未完成筛选不发出请求。
    func removeSelectedResults() {
        guard filterTask == nil, !filter.isEditingInput else {
            return
        }
        let selected = selectedKeys()
        var requests: [SearchResultRemoval] = []
        for batch in batches {
            if selected.contains(SearchResultTreeKey(batch: batch.id)) {
                requests.append(.batch(batch.id))
                continue
            }
            for file in batch.files {
                if selected.contains(SearchResultTreeKey(batch: batch.id, file: file.id)) {
                    requests.append(.file(batch: batch.id, file: file.id))
                    continue
                }
                let hits = file.rows.filter {
                    selected.contains(SearchResultTreeKey(batch: batch.id, file: file.id, hit: $0.id))
                }.map(\.id)
                if !hits.isEmpty {
                    requests.append(.hits(batch: batch.id, file: file.id, hits: hits))
                }
            }
            for index in batch.notes.indices
            where selected.contains(SearchResultTreeKey(batch: batch.id, note: index)) {
                requests.append(.note(batch: batch.id, index: index))
            }
        }
        guard !requests.isEmpty else {
            return
        }
        // 说明以批次内索引表示，删除前取消选择可避免压缩后的相邻说明继承旧选择。
        outline.deselectAll(nil)
        onRemove?(requests)
    }
}
