import AppKit
import NateCore

extension SearchResultsPanel {
    /// 业务作用：原生按钮只作用于当前保留的批次，清除与隐藏不会关闭或改写源文档。
    /// 参数说明:
    /// - sender: 具有稳定动作标识的当前工具按钮。
    /// 返回：复制、导航、折叠、清除或隐藏的真实操作被执行。
    @objc func performCommand(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "previous": selectNextHit(backwards: true)
        case "next": selectNextHit()
        case "copy": copyResults()
        case "paths": copyPaths()
        case "expand":
            outline.expandItem(nil, expandChildren: true)
        case "collapse":
            expanded.removeAll()
            outline.collapseItem(nil, collapseChildren: true)
        case "remove":
            removeSelectedResults()
        case "clear": onRemoveBatches?(batches.map(\.id))
        case "close": onClose?()
        default: break
        }
    }

    /// 业务作用：Enter 激活当前键盘选择，历史鼠标点击位置不能改变键盘目标。
    /// 参数说明: 无。
    /// 返回：当前命中发出稳定身份，分组切换展开状态。
    @objc func activateSelection() {
        activateItem(at: outline.selectedRow)
    }

    /// 业务作用：原生双击只激活本次点击的结果，多个选区中先前选择不冒充点击目标。
    /// 参数说明: 无。
    /// 返回：当前双击行按稳定身份定位或展开。
    @objc func activateClicked() {
        activateItem(at: outline.clickedRow)
    }

    /// 业务作用：定位前复验可见对象和筛选状态，旧对象或未确认筛选不能取得源文档焦点。
    /// 参数说明:
    /// - row: 当前原生树表中的实际行。
    /// 返回：合法命中向应用发送批次与命中身份，其余只改变内存分组展开状态。
    func activateItem(at row: Int) {
        guard row >= 0, row < outline.numberOfRows, filterTask == nil, !filter.isEditingInput,
            let item = outline.item(atRow: row) as? SearchResultTreeItem, items[item.key] === item
        else {
            return
        }
        if case .hit(let hit, _) = item.value {
            lastActivatedHit = SearchResultTreeKey(batch: item.key.batch, file: item.key.file, hit: hit.id)
            onActivate?(item.key.batch, hit.id)
        }
        else if !item.children.isEmpty {
            if outline.isItemExpanded(item) {
                outline.collapseItem(item)
            }
            else {
                outline.expandItem(item)
            }
        }
    }

    /// 业务作用：在当前筛选的命中序列中连续前后定位，折叠分组不丢失命中身份。
    /// 参数说明:
    /// - backwards: 是否向前一个命中移动。
    /// 返回：目标父级先展开，树表选中稳定命中后请求应用定位；无命中或筛选未完成时保持正文。
    public func selectNextHit(backwards: Bool = false) {
        guard !hitOrder.isEmpty, filterTask == nil, !filter.isEditingInput else {
            return
        }
        let selected =
            outline.selectedRow >= 0
            ? (outline.item(atRow: outline.selectedRow) as? SearchResultTreeItem)?.key : nil
        let index: Int
        let currentKey = selected.flatMap {
            key in
            if let lastActivatedHit, hitDisplayKeys[lastActivatedHit] == key {
                return lastActivatedHit
            }
            return key
        }
        if let currentKey, let current = hitIndices[currentKey] {
            index = (current + (backwards ? hitOrder.count - 1 : 1)) % hitOrder.count
        }
        else {
            index = backwards ? hitOrder.count - 1 : 0
        }
        let key = hitOrder[index]
        guard let display = hitDisplayKeys[key], let item = items[display],
            let file = item.parent, let batch = file.parent,
            let index = hitIndices[key], index < hitValues.count
        else {
            return
        }
        outline.expandItem(batch)
        outline.expandItem(file)
        let row = outline.row(forItem: item)
        guard row >= 0 else {
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        if case .hit(_, let path) = item.value {
            item.value = .hit(hitValues[index], path: path)
            outline.reloadItem(item)
        }
        activateItem(at: row)
    }

    /// 业务作用：复制结果使用完整元数据而不是单元格的短标题，折叠不会丢弃所选分组中的命中。
    /// 参数说明:
    /// - selectedOnly: 是否只导出当前所选节点及其后代，未选择时仍导出当前筛选的完整集合。
    /// 返回：最多 64 MiB 的完整结果文本，超限或没有结果时不产生部分导出。
    public func exportedText(selectedOnly: Bool = false) throws -> String {
        let selected = selectedOnly ? selectedKeys() : []
        var output = ""
        var remaining = 64 * 1024 * 1024
        for result in filtered {
            let rootSelected =
                selected.isEmpty || selected.contains(SearchResultTreeKey(batch: result.batch.id))
            var openedBatch = false
            for file in result.files {
                let fileSelected =
                    rootSelected
                    || selected.contains(SearchResultTreeKey(batch: result.batch.id, file: file.id))
                let rows =
                    fileSelected
                    ? file.rows
                    : file.rows.filter {
                        selected.contains(
                            SearchResultTreeKey(batch: result.batch.id, file: file.id, hit: $0.id)
                        )
                    }
                guard fileSelected || !rows.isEmpty else {
                    continue
                }
                if !openedBatch {
                    try appendExport(
                        "查找：\(result.batch.query)\n范围：\(result.batch.scope)\n选项：\(result.batch.condition.summary)",
                        into: &output,
                        remaining: &remaining
                    )
                    openedBatch = true
                }
                try appendExport(file.path ?? file.name, into: &output, remaining: &remaining)
                for row in rows {
                    try appendExport(row.text, into: &output, remaining: &remaining)
                }
            }
            for note in result.notes
            where rootSelected
                || selected.contains(SearchResultTreeKey(batch: result.batch.id, note: note.index))
            {
                if !openedBatch {
                    try appendExport(
                        "查找：\(result.batch.query)\n范围：\(result.batch.scope)\n选项：\(result.batch.condition.summary)",
                        into: &output,
                        remaining: &remaining
                    )
                    openedBatch = true
                }
                try appendExport(note.text, into: &output, remaining: &remaining)
            }
        }
        guard !output.isEmpty else {
            throw NateError.message("当前没有可复制的结果。")
        }
        return output
    }

    /// 业务作用：路径复制保留原始 UTF-8 文件名，控制字符的可见转义不成为真实文件路径。
    /// 参数说明:
    /// - selectedOnly: 是否只取当前所选节点及后代，未选择时取当前筛选集合。
    /// 返回：按结果顺序排列并按完整字节去重的真实文件路径，未命名文档不伪造路径。
    public func exportedPaths(selectedOnly: Bool = false) -> [String] {
        let selected = selectedOnly ? selectedKeys() : []
        var paths: [String] = []
        var identities: Set<Data> = []
        for result in filtered {
            let rootSelected =
                selected.isEmpty || selected.contains(SearchResultTreeKey(batch: result.batch.id))
            for file in result.files {
                let includes =
                    rootSelected
                    || selected.contains(SearchResultTreeKey(batch: result.batch.id, file: file.id))
                    || file.rows.contains {
                        selected.contains(
                            SearchResultTreeKey(batch: result.batch.id, file: file.id, hit: $0.id)
                        )
                    }
                if includes, let path = file.path, identities.insert(Data(path.utf8)).inserted {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// 业务作用：工具栏和 Command-C 共用完整结果导出，容量失败不会先清空用户剪贴板。
    /// 参数说明: 无。
    /// 返回：完整文本成功准备后写入系统剪贴板，失败留在结果反馈中。
    func copyResults() {
        do {
            let text = try exportedText(selectedOnly: true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            feedback.stringValue = "已复制完整所选结果。"
        }
        catch {
            feedback.stringValue = error.localizedDescription
        }
    }

    /// 业务作用：用户明确请求时才把当前实际路径集合写入剪贴板，不访问或打开这些位置。
    /// 参数说明: 无。
    /// 返回：有路径时写入完整原文；仅未命名文档或说明被选中时明确反馈。
    func copyPaths() {
        let paths = exportedPaths(selectedOnly: true)
        guard !paths.isEmpty else {
            feedback.stringValue = "当前所选结果没有磁盘文件路径。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        feedback.stringValue = "已复制 \(paths.count) 个完整文件路径。"
    }

    /// 业务作用：当前选择只认仍在可见模型中的稳定对象，旧原生索引不取得复制或清除资格。
    /// 参数说明: 无。
    /// 返回：当前合法选择的稳定身份集合。
    func selectedKeys() -> Set<SearchResultTreeKey> {
        Set(
            outline.selectedRowIndexes.flatMap {
                row in
                guard let item = outline.item(atRow: row) as? SearchResultTreeItem, items[item.key] === item
                else {
                    return [] as [SearchResultTreeKey]
                }
                return displayMembers[item.key] ?? [item.key]
            }
        )
    }

    /// 业务作用：清除只引用当前已保留批次，筛选没有命中时仍允许显式清空历史。
    /// 参数说明: 无。
    /// 返回：批次清除按钮反映实际选择与历史状态，不修改结果。
    func updateCommands() {
        clearBatch.isEnabled = !selectedKeys().isEmpty && filterTask == nil && !filter.isEditingInput
        clearAll.isEnabled = !batches.isEmpty
    }

    /// 业务作用：导出先预留完整文本容量，失败不能向剪贴板发布截断结果。
    /// 参数说明:
    /// - text: 下一份完整结果字段或命中行。
    /// - output: 仅在全部成功后才使用的导出缓冲区。
    /// - remaining: 本次导出的剩余 UTF-8 容量。
    /// 返回：容量足够时追加完整字段及换行，超限立即失败。
    func appendExport(_ text: String, into output: inout String, remaining: inout Int) throws {
        let count = text.utf8.count
        guard count < remaining else {
            throw NateError.message("复制结果超过 64 MiB，请先缩小结果范围。")
        }
        remaining -= count + 1
        output.append(text)
        output.append("\n")
    }
}
