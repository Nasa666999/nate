import AppKit

public struct SearchResultFileSelection: Sendable {
    public let batch: UUID
    public let file: UUID

    /// 业务作用：文件操作只传递当前结果分组身份，真实路径由来源拥有者复验后解释。
    /// 参数说明:
    /// - batch: 当前保留的搜索批次。
    /// - file: 该批次内仍存在的文件分组。
    /// 返回：不含旧匹配偏移与文件访问能力的操作请求。
    public init(batch: UUID, file: UUID) {
        self.batch = batch
        self.file = file
    }
}

extension SearchResultsPanel {
    /// 业务作用：打开路径只使用实际选中的可见文件，不把未选择操作扩大到全部历史。
    /// 参数说明: 无。
    /// 返回：按结果顺序排列且按原始路径字节去重的文件身份，未命名文档与说明不提供路径。
    public func selectedResultFiles() -> [SearchResultFileSelection] {
        let selected = selectedKeys()
        guard !selected.isEmpty else {
            return []
        }
        var files: [SearchResultFileSelection] = []
        var paths: Set<Data> = []
        for batch in filtered {
            let wholeBatch = selected.contains(SearchResultTreeKey(batch: batch.batch.id))
            for file in batch.files {
                let includes =
                    wholeBatch || selected.contains(SearchResultTreeKey(batch: batch.batch.id, file: file.id))
                    || file.rows.contains {
                        selected.contains(
                            SearchResultTreeKey(batch: batch.batch.id, file: file.id, hit: $0.id)
                        )
                    }
                if includes, let path = file.path, paths.insert(Data(path.utf8)).inserted {
                    files.append(SearchResultFileSelection(batch: batch.batch.id, file: file.id))
                }
            }
        }
        return files
    }

    /// 业务作用：显式打开所选路径读取当前文件，与按原匹配证据定位保持独立。
    /// 参数说明: 无。
    /// 返回：至多二十个所选真实路径交给工作区，候选、未完成筛选、无选择或超量时不访问文件。
    @objc func openSelectedResultPaths() {
        guard filterTask == nil, !filter.isEditingInput else {
            return
        }
        let selection = selectedResultFiles()
        guard !selection.isEmpty, selection.count <= 20 else {
            feedback.stringValue =
                selection.isEmpty
                ? "请先选中带文件路径的结果；未命名文档和说明没有磁盘路径。"
                : "一次最多打开二十个所选路径，请缩小选择范围。"
            return
        }
        onOpenPaths?(selection)
    }
}
