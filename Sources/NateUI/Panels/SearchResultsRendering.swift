import AppKit

extension SearchResultsPanel {
    /// 业务作用：完整筛选结果以稳定对象发布，选择、展开和视口跟随真实结果身份而非旧行号。
    /// 参数说明:
    /// - output: 同一历史快照生成的完整筛选树。
    /// 返回：原生树表完整刷新，正文焦点、源选区及文档内容保持不变。
    func publish(_ output: SearchResultFilterOutput) {
        let selected = selectedKeys()
        let topRow = outline.row(at: NSPoint(x: 1, y: scroll.contentView.bounds.minY + 1))
        let top = topRow >= 0 ? (outline.item(atRow: topRow) as? SearchResultTreeItem)?.key : nil
        let topOffset = topRow >= 0 ? scroll.contentView.bounds.minY - outline.rect(ofRow: topRow).minY : 0
        let previous = Set(
            roots.map {
                $0.key.batch
            }
        )
        for item in items.values where !item.children.isEmpty {
            if outline.isItemExpanded(item) {
                expanded.insert(item.key)
            }
            else {
                expanded.remove(item.key)
            }
        }
        let retained = Set(batches.map(\.id))
        expanded = expanded.filter {
            retained.contains($0.batch)
        }
        var nextItems: [SearchResultTreeKey: SearchResultTreeItem] = [:]
        var nextRoots: [SearchResultTreeItem] = []
        var order: [SearchResultTreeKey] = []
        var values: [SearchPreviewRow] = []
        var displayKeys: [SearchResultTreeKey: SearchResultTreeKey] = [:]
        var members: [SearchResultTreeKey: [SearchResultTreeKey]] = [:]
        var fileCounts: [SearchResultTreeKey: Int] = [:]
        for result in output.batches {
            let root = resultItem(
                key: SearchResultTreeKey(batch: result.batch.id),
                value: .batch(result.batch),
                parent: nil,
                into: &nextItems
            )
            nextRoots.append(root)
            for file in result.files {
                let group = resultItem(
                    key: SearchResultTreeKey(batch: result.batch.id, file: file.id),
                    value: .file(file),
                    parent: root,
                    into: &nextItems
                )
                root.children.append(group)
                let groups = resultGroups(file.rows)
                fileCounts[group.key] = groups.count
                for rows in groups {
                    guard let row = rows.first else {
                        continue
                    }
                    let key = SearchResultTreeKey(batch: result.batch.id, file: file.id, hit: row.id)
                    let active = rows.first {
                        $0.id == lastActivatedHit?.hit && key.batch == lastActivatedHit?.batch
                    }
                    group.children.append(
                        resultItem(
                            key: key,
                            value: .hit(active ?? row, path: file.path),
                            parent: group,
                            into: &nextItems
                        )
                    )
                    for match in rows {
                        let hit = SearchResultTreeKey(batch: result.batch.id, file: file.id, hit: match.id)
                        displayKeys[hit] = key
                        members[key, default: []].append(hit)
                    }
                }
                // 展示分组不能改变搜索引擎的实际命中顺序，连续导航仍覆盖同一行中的每个匹配。
                for row in file.rows {
                    order.append(SearchResultTreeKey(batch: result.batch.id, file: file.id, hit: row.id))
                    values.append(row)
                }
            }
            for note in result.notes {
                root.children.append(
                    resultItem(
                        key: SearchResultTreeKey(batch: result.batch.id, note: note.index),
                        value: .note(note.text),
                        parent: root,
                        into: &nextItems
                    )
                )
            }
            if !previous.contains(root.key.batch) {
                expanded.insert(root.key)
                if let first = root.children.first, case .file = first.value {
                    expanded.insert(first.key)
                }
            }
        }
        rebuilding = true
        defer {
            rebuilding = false
        }
        filtered = output.batches
        roots = nextRoots
        items = nextItems
        hitOrder = order
        hitValues = values
        hitDisplayKeys = displayKeys
        displayMembers = members
        fileDisplayCounts = fileCounts
        if let lastActivatedHit, displayKeys[lastActivatedHit] == nil {
            self.lastActivatedHit = nil
        }
        hitIndices = Dictionary(
            uniqueKeysWithValues: order.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        visibleMatchCount = output.visibleRows
        visibleRowCount = members.count
        outline.deselectAll(nil)
        outline.reloadData()
        for root in roots where expanded.contains(root.key) {
            outline.expandItem(root)
            for child in root.children where expanded.contains(child.key) && !child.children.isEmpty {
                outline.expandItem(child)
            }
        }
        let selectedRows = IndexSet(
            selected.compactMap {
                key in
                guard let item = items[displayKeys[key] ?? key] else {
                    return nil
                }
                let row = outline.row(forItem: item)
                return row >= 0 ? row : nil
            }
        )
        outline.selectRowIndexes(selectedRows, byExtendingSelection: false)
        if let top, let item = items[displayKeys[top] ?? top] {
            let row = outline.row(forItem: item)
            if row >= 0 {
                let y = max(0, outline.rect(ofRow: row).minY + topOffset)
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let original = batches.reduce(0) {
            $0 + $1.initialMatchCount
        }
        feedback.stringValue =
            "\(batches.count) 批 · 原始 \(original) 处 · 可见 \(output.visibleRows) 处 / \(visibleRowCount) 项"
        updateCommands()
        onPresentationChange?()
    }

    /// 业务作用：重用相同稳定身份的原生对象，旧行号不会在过滤或重排后指向另一条命中。
    /// 参数说明:
    /// - key: 当前批次内的完整稳定身份。
    /// - value: 本次完整展示值。
    /// - parent: 当前父行，根批次为空。
    /// - next: 仅保留本次可见树的对象索引。
    /// 返回：已更新且尚未加入子项的稳定行对象，移除的结果不残留在索引中。
    func resultItem(
        key: SearchResultTreeKey,
        value: SearchResultTreeValue,
        parent: SearchResultTreeItem?,
        into next: inout [SearchResultTreeKey: SearchResultTreeItem]
    ) -> SearchResultTreeItem {
        let item = items[key] ?? SearchResultTreeItem(key: key, value: value)
        item.value = value
        item.parent = parent
        item.children.removeAll(keepingCapacity: true)
        next[key] = item
        return item
    }

    /// 业务作用：原生树表仅查询已完成的内存结果，不在展开或滚动时读取源文件。
    /// 参数说明:
    /// - outlineView: 当前结果树。
    /// - item: 稳定父对象，空值表示批次层。
    /// 返回：当前父级完整子项数量。
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SearchResultTreeItem)?.children.count ?? roots.count
    }

    /// 业务作用：将原生层内索引映射到当前稳定结果对象，定位回调不依赖该索引。
    /// 参数说明:
    /// - outlineView: 当前结果树。
    /// - index: 当前层内有效索引。
    /// - item: 当前父对象。
    /// 返回：该层对应的稳定批次、文件、命中或说明对象。
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SearchResultTreeItem)?.children[index] ?? roots[index]
    }

    /// 业务作用：只给实际有子项的分组显示展开入口，说明和命中不会伪装成目录。
    /// 参数说明:
    /// - outlineView: 当前结果树。
    /// - item: 待查询的稳定结果对象。
    /// 返回：当前对象确有内存子项时为真。
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SearchResultTreeItem else {
            return false
        }
        return !item.children.isEmpty
    }

    /// 业务作用：按批次、文件和命中身份呈现不同层级，命中高亮直接使用转义上下文的固定坐标。
    /// 参数说明:
    /// - outlineView: 当前结果树。
    /// - tableColumn: 当前结果列。
    /// - item: 具有当前呈现资格的结果对象。
    /// 返回：可复用的单行文本单元格，控制字符不产生额外可点击行。
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let item = item as? SearchResultTreeItem, items[item.key] === item else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("search-result-text")
        let field =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .labelColor
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.font = font
        field.toolTip = nil
        switch item.value {
        case .batch(let batch):
            field.stringValue =
                "查找 “\(SearchResultLabel.display(batch.query, limit: 96))” · \(batch.condition.options.mode.rawValue) · 原始 \(batch.initialMatchCount) 处 · \(SearchResultLabel.display(batch.scope, limit: 160))"
            field.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            field.toolTip = batch.condition.summary
        case .file(let file):
            field.stringValue =
                "\(SearchResultLabel.display(file.path ?? file.name)) · \(file.matchCount) 处，显示 \(fileDisplayCounts[item.key] ?? file.rows.count) 项"
            field.toolTip = SearchResultLabel.display(file.path ?? file.name, limit: 16_384)
        case .hit(let row, _):
            let count = displayMembers[item.key]?.count ?? 1
            let group = count > 1 ? " · 本行 \(count) 处" : ""
            let prefix = "行 \(row.line) · UTF-16 列 \(row.column)\(group)  "
            let text = NSMutableAttributedString(
                string: prefix + row.context,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            if let highlight = row.highlight {
                text.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.35),
                    range: NSRange(
                        location: prefix.utf16.count + highlight.location,
                        length: highlight.length
                    )
                )
            }
            field.attributedStringValue = text
        case .note(let note):
            field.stringValue = SearchResultLabel.display(note)
            field.textColor = .secondaryLabelColor
            field.toolTip = SearchResultLabel.display(note, limit: 16_384)
        }
        return field
    }

    /// 业务作用：用户改选结果会撤销等待中的旧定位，刷新期间的机械选区恢复不产生新导航意图。
    /// 参数说明:
    /// - notification: 原生树表选择通知。
    /// 返回：工具状态更新，用户选择变化通知拥有者收回旧呈现权限。
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateCommands()
        if !rebuilding {
            lastActivatedHit = nil
            onPresentationChange?()
        }
    }
}
